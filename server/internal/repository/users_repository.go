package repository

import (
	"context"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// User is a row of the users table.
type User struct {
	ID           string
	Username     string
	Slug         string
	DisplayName  string
	Role         string
	PasswordHash string
	QuotaBytes   *int64
	CreatedAt    time.Time
	DisabledAt   *time.Time
}

// UsersRepository accesses the users table.
type UsersRepository struct{}

func userFromRow(r queries.User) (User, error) {
	created, err := parseTime(r.CreatedAt)
	if err != nil {
		return User{}, err
	}
	dis, err := parseTimePtr(r.DisabledAt)
	if err != nil {
		return User{}, err
	}
	return User{
		ID: r.ID, Username: r.Username, Slug: r.Slug, DisplayName: r.DisplayName, Role: r.Role,
		PasswordHash: r.PasswordHash, QuotaBytes: r.QuotaBytes, CreatedAt: created, DisabledAt: dis,
	}, nil
}

// Insert adds a user; ErrUniqueViolation on a duplicate id, username or slug.
func (UsersRepository) Insert(ctx context.Context, db queries.DBTX, u User) error {
	return mapErr(queries.New(db).InsertUser(ctx, queries.InsertUserParams{
		ID: u.ID, Username: u.Username, Slug: u.Slug, DisplayName: u.DisplayName, Role: u.Role,
		PasswordHash: u.PasswordHash, QuotaBytes: u.QuotaBytes,
		CreatedAt: formatTime(u.CreatedAt), DisabledAt: formatTimePtr(u.DisabledAt),
	}))
}

// GetByID returns the user or ErrNotFound.
func (UsersRepository) GetByID(ctx context.Context, db queries.DBTX, id string) (User, error) {
	r, err := queries.New(db).GetUserByID(ctx, id)
	if err != nil {
		return User{}, mapErr(err)
	}
	return userFromRow(r)
}

// GetByUsername looks a user up case-insensitively, or returns ErrNotFound.
func (UsersRepository) GetByUsername(ctx context.Context, db queries.DBTX, username string) (User, error) {
	r, err := queries.New(db).GetUserByUsername(ctx, username)
	if err != nil {
		return User{}, mapErr(err)
	}
	return userFromRow(r)
}

// Count returns the number of users.
func (UsersRepository) Count(ctx context.Context, db queries.DBTX) (int64, error) {
	return queries.New(db).CountUsers(ctx)
}

// SetPasswordHash replaces a user's password hash.
func (UsersRepository) SetPasswordHash(ctx context.Context, db queries.DBTX, id, hash string) error {
	return requireRow(queries.New(db).SetUserPasswordHash(ctx, queries.SetUserPasswordHashParams{PasswordHash: hash, ID: id}))
}

// List returns every user ordered by creation time.
func (UsersRepository) List(ctx context.Context, db queries.DBTX) ([]User, error) {
	rows, err := queries.New(db).ListUsers(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]User, 0, len(rows))
	for _, r := range rows {
		u, err := userFromRow(r)
		if err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, nil
}
