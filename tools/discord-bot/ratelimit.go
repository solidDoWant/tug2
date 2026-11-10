package main

import (
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

// RefundIssue gives back the most recent issue slot, for a filing that failed.
func (r *RateLimiter) RefundIssue(user string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if n := len(r.issues[user]); n > 0 {
		r.issues[user] = r.issues[user][:n-1]
	}
}
