package voice

import "testing"

func TestCenterOut(t *testing.T) {
	cases := map[int][]int{
		1: {0},
		2: {0, 1},
		5: {2, 1, 3, 0, 4},
		6: {2, 3, 1, 4, 0, 5},
	}
	for n, want := range cases {
		got := CenterOut(n)
		if len(got) != len(want) {
			t.Fatalf("CenterOut(%d) = %v, want %v", n, got, want)
		}
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("CenterOut(%d) = %v, want %v", n, got, want)
			}
		}
	}
}

// The first agents to arrive should sit in front of the listener: with an
// empty room the pick is the centre seat's persona, then its neighbour.
func TestPickCenterFirst(t *testing.T) {
	r := Default()
	first := r.Pick(map[string]bool{})
	if seat := r.Seat(first.Name); seat != 2 {
		t.Fatalf("first pick = %s (seat %d), want the centre seat 2", first.Name, seat)
	}
	second := r.Pick(map[string]bool{first.Name: true})
	if seat := r.Seat(second.Name); seat != 3 {
		t.Fatalf("second pick = %s (seat %d), want seat 3", second.Name, seat)
	}
}
