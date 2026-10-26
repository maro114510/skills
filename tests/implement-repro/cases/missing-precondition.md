# Converted amounts ignore a rate update

## Background

The long-running worker converts amounts with `rates_convert`.
Treasury publishes new rates through `rates_set`, but the worker keeps converting at the old rate.

## Requirements

- After `rates_set CODE RATE`, `rates_convert AMOUNT CODE` uses `RATE`.
- `rates_set` keeps rejecting a rate that is not positive.

## Acceptance Criteria

1. `rates_convert` uses the rate most recently passed to `rates_set`.
2. `rates_set CODE 0` still fails with status 1.
