// Waveform dumping for the Clash-generated Verilog test bench.
//
// Clash does not emit $dumpvars, and the generated testBench.v must not be
// edited, so this is compiled in as a second root module alongside it:
//
//   iverilog -s testBench -s dump ...
//
// $dumpvars(0, testBench) recurses through the whole hierarchy, so every
// register in the design shows up in the viewer.
`timescale 100fs/100fs

module dump;
  initial begin
    $dumpfile("sim/testBench.vcd");
    $dumpvars(0, testBench);
  end
endmodule
