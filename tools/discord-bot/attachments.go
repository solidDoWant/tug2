package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strings"

	"github.com/bwmarrin/discordgo"
	"github.com/google/go-github/v93/github"
)

// Screenshots the reporter posted in the conversation go into the issue.
//
// GitHub's REST API has no way to upload an image to an issue (the web UI's
// user-attachments upload needs a browser session), and Discord's attachment
// URLs are signed and expire after about a day, so linking them would leave
// broken images in the issue. Instead, at filing time the bot downloads each
// image from Discord and commits it to a public repository with the same
// GitHub App (GITHUB_ATTACHMENTS_REPO), and the issue embeds the committed
// file. Storage sits behind MediaStore, so another backend (an S3 bucket, say)
// only needs a Put.
//
// The draft lists the images as links to the Discord messages they are in,
// rather than as CDN URLs, because the draft lives only in its embed and may
// be confirmed after the CDN URLs expire. Confirming re-reads those messages
// for fresh URLs, so deleting a message before confirming leaves its image
// out.

// MediaStore keeps a copy of a file where a public GitHub issue can show it
// for good.
type MediaStore interface {
	// Put stores data at path (unique per attachment, so a retried filing
	// writes the same path again) and returns its public URL.
	Put(ctx context.Context, path string, data []byte) (string, error)
}

const (
	// maxIssueImages caps how many images one issue carries.
	maxIssueImages = 5
	// maxImageBytes skips anything bigger; Discord's free upload limit.
	maxImageBytes = 10 << 20
	// draftAttachmentsField is the draft embed field listing the images; its
	// name carries the warning that they become public.
	draftAttachmentsField = "Screenshots (public on GitHub once filed)"
)

// AttachmentRef is one image on a draft: its file name and the message it is
// attached to.
type AttachmentRef struct {
	Name                          string
	GuildID, ChannelID, MessageID string
}

func (r AttachmentRef) link() string {
	return fmt.Sprintf("https://discord.com/channels/%s/%s/%s", r.GuildID, r.ChannelID, r.MessageID)
}

// IssueImage is an image copied to the media store, ready to embed.
type IssueImage struct {
	Name, URL string
}

// attachmentLabel is how an attachment's file name shows on the draft, and
// how it is matched again when filing: markdown-safe and bounded so five fit
// in one embed field.
func attachmentLabel(filename string) string {
	return truncate(strings.Map(func(r rune) rune {
		if strings.ContainsRune("[]()`*_~|<>\\\n", r) {
			return '-'
		}
		return r
	}, filename), 60)
}

func isImage(a *discordgo.MessageAttachment) bool {
	if a.ContentType != "" {
		return strings.HasPrefix(a.ContentType, "image/")
	}
	name := strings.ToLower(a.Filename)
	for _, ext := range []string{".png", ".jpg", ".jpeg", ".gif", ".webp"} {
		if strings.HasSuffix(name, ext) {
			return true
		}
	}
	return false
}

// reporterImages lists the images the reporter attached to their own
// messages in the conversation, oldest first, up to maxIssueImages. Other
// people's images, and files that aren't images, are left out.
func reporterImages(msgs []*discordgo.Message, reporterID, guildID string) []AttachmentRef {
	var refs []AttachmentRef
	for _, m := range msgs {
		if m.Author == nil || m.Author.ID != reporterID {
			continue
		}
		for _, a := range m.Attachments {
			if !isImage(a) || a.Size > maxImageBytes {
				continue
			}
			if len(refs) == maxIssueImages {
				return refs
			}
			refs = append(refs, AttachmentRef{Name: attachmentLabel(a.Filename), GuildID: guildID, ChannelID: m.ChannelID, MessageID: m.ID})
		}
	}
	return refs
}

func attachmentsField(refs []AttachmentRef) *discordgo.MessageEmbedField {
	lines := make([]string, len(refs))
	for i, r := range refs {
		lines[i] = fmt.Sprintf("[%s](%s)", r.Name, r.link())
	}
	return &discordgo.MessageEmbedField{Name: draftAttachmentsField, Value: strings.Join(lines, "\n")}
}

var attachmentLine = regexp.MustCompile(`^\[(.+)\]\(https://discord\.com/channels/(\d+)/(\d+)/(\d+)\)$`)

// draftAttachments reads the images back from a draft's embed.
func draftAttachments(embed *discordgo.MessageEmbed) []AttachmentRef {
	var refs []AttachmentRef
	for _, f := range embed.Fields {
		if f.Name != draftAttachmentsField {
			continue
		}
		for line := range strings.Lines(f.Value) {
			if m := attachmentLine.FindStringSubmatch(strings.TrimSpace(line)); m != nil {
				refs = append(refs, AttachmentRef{Name: m[1], GuildID: m[2], ChannelID: m[3], MessageID: m[4]})
			}
		}
	}
	return refs
}

// messageGetter is the part of the Discord session that copying images uses.
type messageGetter interface {
	ChannelMessage(channelID, messageID string, options ...discordgo.RequestOption) (*discordgo.Message, error)
}

// copyAttachments copies the draft's images to the store, for filing.
// threadID keeps each thread's files together. An image that can't be copied
// (its message was deleted, Discord or the store failed) is logged and
// counted in missing, so the issue is still filed.
func copyAttachments(ctx context.Context, log *slog.Logger, discord messageGetter, client *http.Client, store MediaStore,
	threadID string, refs []AttachmentRef) (images []IssueImage, missing int) {
	for _, ref := range refs {
		img, err := copyAttachment(ctx, discord, client, store, threadID, ref)
		if err != nil {
			log.Warn("copying screenshot to the issue", "attachment", ref.Name, "message", ref.MessageID, "err", err)
			missing++
			continue
		}
		images = append(images, img)
	}
	return images, missing
}

func copyAttachment(ctx context.Context, discord messageGetter, client *http.Client, store MediaStore, threadID string, ref AttachmentRef) (IssueImage, error) {
	// Re-read the message: its attachment URLs are signed and may have
	// expired since the draft was posted.
	m, err := discord.ChannelMessage(ref.ChannelID, ref.MessageID)
	if err != nil {
		return IssueImage{}, fmt.Errorf("reading the message: %w", err)
	}
	var att *discordgo.MessageAttachment
	for _, a := range m.Attachments {
		if attachmentLabel(a.Filename) == ref.Name && isImage(a) {
			att = a
			break
		}
	}
	if att == nil {
		return IssueImage{}, errors.New("no longer attached to the message")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, att.URL, nil)
	if err != nil {
		return IssueImage{}, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return IssueImage{}, fmt.Errorf("downloading: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return IssueImage{}, fmt.Errorf("downloading: %s", resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxImageBytes+1))
	if err != nil {
		return IssueImage{}, fmt.Errorf("downloading: %w", err)
	}
	if len(data) > maxImageBytes {
		return IssueImage{}, errors.New("larger than 10 MB")
	}
	url, err := store.Put(ctx, fmt.Sprintf("discord/%s/%s-%s", threadID, att.ID, safePathName(att.Filename)), data)
	if err != nil {
		return IssueImage{}, fmt.Errorf("storing: %w", err)
	}
	return IssueImage{Name: ref.Name, URL: url}, nil
}

// safePathName keeps a file name to characters that need no escaping in a
// repository path or URL.
func safePathName(name string) string {
	name = strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '.', r == '-', r == '_':
			return r
		}
		return '_'
	}, name)
	if len(name) > 80 {
		name = name[len(name)-80:] // keep the extension
	}
	return name
}

// githubMediaStore commits files to a public GitHub repository and serves
// them from raw.githubusercontent.com, which GitHub's image proxy embeds in
// issues. Its client's token is limited to that repository's contents.
type githubMediaStore struct {
	client              *github.Client
	owner, repo, branch string
}

func (s *githubMediaStore) Put(ctx context.Context, path string, data []byte) (string, error) {
	url := fmt.Sprintf("https://raw.githubusercontent.com/%s/%s/%s/%s", s.owner, s.repo, s.branch, path)
	_, _, err := s.client.Repositories.CreateFile(ctx, s.owner, s.repo, path, &github.RepositoryContentFileOptions{
		Message: new("Add screenshot for a Discord issue report"),
		Content: data,
		Branch:  new(s.branch),
	})
	var ghErr *github.ErrorResponse
	if errors.As(err, &ghErr) && ghErr.Response != nil && ghErr.Response.StatusCode == http.StatusUnprocessableEntity {
		// Already there: a retry after a failed filing. Paths are unique
		// per attachment, so it is the same file.
		if _, _, _, getErr := s.client.Repositories.GetContents(ctx, s.owner, s.repo, path,
			&github.RepositoryContentGetOptions{Ref: s.branch}); getErr == nil {
			return url, nil
		}
	}
	if err != nil {
		return "", fmt.Errorf("committing %s to %s/%s: %w", path, s.owner, s.repo, err)
	}
	return url, nil
}
