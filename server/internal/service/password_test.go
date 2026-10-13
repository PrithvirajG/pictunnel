package service

import (
	"regexp"
	"testing"
)

func TestPasswordDefaultParams(t *testing.T) {
	saved := argonParams
	argonParams = defaultArgonParams
	defer func() { argonParams = saved }()

	h, err := hashPassword(testPassword)
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(`^\$argon2id\$v=19\$m=65536,t=3,p=2\$[A-Za-z0-9+/]{22}\$[A-Za-z0-9+/]{43}$`)
	if !re.MatchString(h) {
		t.Fatalf("hash %q is not the expected PHC string", h)
	}
	if !verifyPassword(h, testPassword) {
		t.Fatal("verify failed with the correct password")
	}
}

func TestPasswordVerify(t *testing.T) {
	h, err := hashPassword(testPassword)
	if err != nil {
		t.Fatal(err)
	}
	h2, _ := hashPassword(testPassword)
	if h == h2 {
		t.Fatal("two hashes of the same password are equal; salt not random")
	}
	if !verifyPassword(h, testPassword) {
		t.Fatal("correct password rejected")
	}
	if verifyPassword(h, testPassword+"x") {
		t.Fatal("wrong password accepted")
	}
	for _, bad := range []string{
		"", "h", "$argon2i$v=19$m=64,t=1,p=1$AAAA$AAAA", "$argon2id$v=18$m=64,t=1,p=1$AAAAAAAAAAAAAAAAAAAAAA$AAAA",
		"$argon2id$v=19$m=x,t=1,p=1$AAAAAAAAAAAAAAAAAAAAAA$AAAA", "$argon2id$v=19$m=64,t=1,p=1$!!$AAAA",
		"$argon2id$v=19$m=99999999,t=1,p=1$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
	} {
		if verifyPassword(bad, testPassword) {
			t.Fatalf("garbage hash %q accepted", bad)
		}
	}
}
