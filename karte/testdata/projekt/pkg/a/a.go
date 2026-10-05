package a

// Arena ist das Spielfeld.
type Arena struct {
	Radius int
}

// Parse liest eine Arena.
func Parse(raw []byte) (*Arena, error) {
	return &Arena{}, nil
}

func (a *Arena) Run(n int) {
	a.Run(n - 1)
}
