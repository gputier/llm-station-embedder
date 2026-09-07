# Contributing

Contributions are welcome. This repository has one rule that matters more than
the rest, so it comes first.

## Every claim about a setting needs its measurement

The value of these repositories is not the scripts, it is the numbers attached
to each flag. A pull request that changes a launch parameter, a quantisation, a
batch size or a cache type must say:

- what you measured, with the exact command or request;
- on what hardware, with the GPU, the driver and the llama.cpp build;
- how many runs, and whether the seed was fixed;
- what the number was before, and after.

This is not bureaucracy. Several settings in this repository were changed twice
because the first sweep ran without a fixed seed and measured nothing but noise,
and one community-published value for the exact same card and model turned out
to be 12% slower here. A benchmark that does not resemble the workload can
invert the ranking outright.

If you cannot measure it, say so and open an issue instead. An observation
labelled as an observation is useful. An observation presented as a result is
not.

## Negative results are wanted

An hypothesis you tested and disproved is worth a pull request. Half of the
comments in `llm-ctl.ps1` exist to stop the next person re-testing something
that was already found to gain nothing. If you tried a flag and it did nothing,
that is information.

## Your hardware is not this hardware

Throughput figures do not transpose between cards, and this repository has two
documented cases where the *direction* of an effect transposed while its
magnitude did not. If you run different hardware, please frame your results as
an additional data point rather than a correction, unless you can show the
existing number was wrong on the hardware it was measured on.

## Scope

In scope: the control scripts, the launchers, the documentation, and
measurements on the models already served here.

Out of scope: adding models nobody in this repository can test, and anything
that couples these scripts to a specific network, host or user. Everything here
is meant to run on someone else's machine with three paths changed.

## Style

- Documentation and code comments in English.
- Comments explain **why**, with the number behind the why. A comment that
  restates what the code does is noise.
- No secrets, no hostnames, no IP addresses, no usernames. Configuration that
  varies by installation goes in a variable at the top of the file, or in an
  environment variable.

## Reporting a vulnerability

Not through a pull request. See [SECURITY.md](SECURITY.md).
