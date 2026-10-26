# ratecard

Currency rates and a shopping cart in bash 3.2 or later.

Run the tests with `bash tests/run.sh`.
Pass test files to run only those, `--seed N` to run them in a shuffled order, and `--only NAME` to run one test.

A test is a `test_*` function in `tests/test_*.sh`.
Cart tests reuse `SHARED_CART` from `tests/fixtures.sh` instead of building a cart in every test.
