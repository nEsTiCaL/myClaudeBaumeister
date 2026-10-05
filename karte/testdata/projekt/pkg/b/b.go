package b

import (
	"flag"

	"x.org/demo/pkg/a"
)

type Opt struct {
	Arena *a.Arena
}

func Use(o Opt) {
	flag.Parse()
	ar, _ := a.Parse(nil)
	ar.Run(1)
	_ = o.Arena
	_ = "Parse"
}
