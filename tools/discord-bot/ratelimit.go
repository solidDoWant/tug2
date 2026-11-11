package main

import (
	"fmt"
	"sync"
	"time"
)

// RateLimiter enforces per-user sliding-window limits on questions (per hour)
// and filed issues (per day). Each user gets the defaults unless overrides
// has an entry for them. It is in memory, so a restart resets the counts;
// that is acceptable for a cost and spam guard. A limit of 0 means no limit.
type RateLimiter struct {
	mu        sync.Mutex
	questions map[string][]time.Time
	issues    map[string][]time.Time
	perHour   int
	perDay    int
	overrides map[string]UserLimit
	now       func() time.Time
}

func NewRateLimiter(questionsPerHour, issuesPerDay int, overrides map[string]UserLimit) *RateLimiter {
	return &RateLimiter{
		questions: map[string][]time.Time{},
		issues:    map[string][]time.Time{},
		perHour:   questionsPerHour,
		perDay:    issuesPerDay,
		overrides: overrides,
		now:       time.Now,
	}
}

// limitsFor returns the question and issue limits that apply to user.
func (r *RateLimiter) limitsFor(user string) (questionsPerHour, issuesPerDay int) {
	questionsPerHour, issuesPerDay = r.perHour, r.perDay
	if o, ok := r.overrides[user]; ok {
		if o.QuestionsPerHour != nil {
			questionsPerHour = *o.QuestionsPerHour
		}
		if o.IssuesPerDay != nil {
			issuesPerDay = *o.IssuesPerDay
		}
	}
	return questionsPerHour, issuesPerDay
}

// allow records an event for user if fewer than limit happened in window, and
// otherwise reports how long until the oldest one expires.
func (r *RateLimiter) allow(events map[string][]time.Time, user string, limit int, window time.Duration) (bool, time.Duration) {
	if limit <= 0 {
		return true, 0
	}
	r.mu.Lock()
	defer r.mu.Unlock()

	now := r.now()
	recent := events[user][:0]
	for _, t := range events[user] {
		if now.Sub(t) < window {
			recent = append(recent, t)
		}
	}
	if len(recent) >= limit {
		events[user] = recent
		return false, window - now.Sub(recent[0])
	}
	events[user] = append(recent, now)
	return true, 0
}

func (r *RateLimiter) AllowQuestion(user string) (bool, time.Duration) {
	limit, _ := r.limitsFor(user)
	return r.allow(r.questions, user, limit, time.Hour)
}

func (r *RateLimiter) AllowIssue(user string) (bool, time.Duration) {
	_, limit := r.limitsFor(user)
	return r.allow(r.issues, user, limit, 24*time.Hour)
}

// Reset forgets user's recent questions and issues, so their full limits are
// available again. It reports how many of each it cleared. Other users'
// counts are untouched.
func (r *RateLimiter) Reset(user string) (questions, issues int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.now()
	questions = countWithin(r.questions[user], now, time.Hour)
	issues = countWithin(r.issues[user], now, 24*time.Hour)
	delete(r.questions, user)
	delete(r.issues, user)
	return questions, issues
}

func countWithin(events []time.Time, now time.Time, window time.Duration) int {
	n := 0
	for _, t := range events {
		if now.Sub(t) < window {
			n++
		}
	}
	return n
}

// RefundQuestion gives back the most recent question slot, for a message the
// bot decided wasn't meant for it.
func (r *RateLimiter) RefundQuestion(user string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if n := len(r.questions[user]); n > 0 {
		r.questions[user] = r.questions[user][:n-1]
	}
}

// RefundIssue gives back the most recent issue slot, for a filing that failed.
func (r *RateLimiter) RefundIssue(user string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if n := len(r.issues[user]); n > 0 {
		r.issues[user] = r.issues[user][:n-1]
	}
}

// questionLimitMessage tells a user they've reached their own question limit.
// It says the limit is theirs alone: people seeing it often assume the bot is
// down for everyone.
func questionLimitMessage(limit int, wait time.Duration) string {
	return fmt.Sprintf("You've asked %s in the last hour, which is your limit. The limit is per person, so others can still ask. You can ask again in %s.",
		plural(limit, "question"), aboutDuration(wait))
}

// issueLimitMessage is questionLimitMessage for filed issues.
func issueLimitMessage(limit int, wait time.Duration) string {
	return fmt.Sprintf("You've filed %s in the last 24 hours, which is your limit. The limit is per person. You can file another in %s.",
		plural(limit, "issue"), aboutDuration(wait))
}

// aboutDuration says roughly how long a wait is, in words.
func aboutDuration(d time.Duration) string {
	switch {
	case d < time.Minute:
		return "less than a minute"
	case d < 90*time.Minute:
		return "about " + plural(int((d+30*time.Second)/time.Minute), "minute")
	default:
		return "about " + plural(int((d+30*time.Minute)/time.Hour), "hour")
	}
}

func plural(n int, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	return fmt.Sprintf("%d %ss", n, noun)
}
