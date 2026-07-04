package channel

import "testing"

func TestSlugFromRemote(t *testing.T) {
	cases := map[string]string{
		"git@github.com:cfoust/antiphon.git":     "cfoust/antiphon",
		"git@github.com:cfoust/antiphon":         "cfoust/antiphon",
		"https://github.com/cfoust/antiphon.git": "cfoust/antiphon",
		"https://github.com/cfoust/antiphon":     "cfoust/antiphon",
		"ssh://git@github.com/cfoust/antiphon":   "cfoust/antiphon",
		"git@gitlab.com:group/project.git":       "group/project",
	}
	for in, want := range cases {
		if got := slugFromRemote(in); got != want {
			t.Errorf("slugFromRemote(%q) = %q, want %q", in, got, want)
		}
	}
}
