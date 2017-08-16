# SafetySynth

A symbolic safety game solver written in Swift.
It follows the rules of the [Reactive Synthesis Competition](http://www.syntcomp.org).

## Awards

* First and second place in sequential AIGER synthesis track (SYNTOMP 2017)
* Second place in sequential AIGER realizability track (SYNTOMP 2017)
* First and second place in sequential AIGER synthesis track (SYNTOMP 2016)
* Third place in sequential AIGER realizability track (SYNTOMP 2016)


## Installation

* Requires Swift (version 3.1)
* `make release` builds dependencies and the binary
* `.build/release/SafetySynth [--synthesize] instance.aag`


## How to Generate AIGER Synthesis Files

The synthesis specification file format is described in [Extended AIGER Format for Synthesis](https://arxiv.org/abs/1405.5793).
Instead of generating AIGER files directly, one can describe the game as a Verilog file and compile it down to AIGER using the [yosys](http://www.clifford.at/yosys/) toolset.

### Example 

Consider the following example game, played on a 2-bit state space representing a binary counter.
The input player can `increase` the counter, while the output player can `reset` the counte to zero once the value `2` is reached.
The output player should avoid the value `3`.

```verilog
module counter(increase, controllable_reset, err);
  input increase;
  input controllable_reset; // inputs with prefix `controllable_` are to be synthesized
  output err;
  reg [1:0] state;

  assign err = (state == 3) ;  // single output is specification, should be always 0

  // encoding of transition function
  initial
  begin
    state = 0;
  end
  always @($global_clock)
  begin
    case(state)
        0 : if (!increase)
                state = 0;
            else
                state = 1;
        1 : if (!increase)
                state = 1;
            else
                state = 2;
        2 : if (!increase && !controllable_reset)
                state = 2;
            else if (increase && !contollable_reset)
                state = 3;
            else
                state = 0;
        3 : state = 3;
    endcase
  end
endmodule
```

This verilog file can be encoded in AIGER using the following yosys commands:

```
$ read_verilog counter.v 
$ synth -flatten -top counter
$ abc -g AND
$ write_aiger -ascii -symbols counter.aag
```

The resulting AIGER file can be directly solved using SafetySynth.