test_converts_with_the_default_rate() {
  rates_reset
  rates_convert 100 EUR
  assert_eq 125 "${REPLY}"
}

test_unknown_currency_fails() {
  rates_reset
  assert_status 1 rates_convert 100 XXX
}

test_set_rate_rejects_a_zero_rate() {
  rates_reset
  assert_status 1 rates_set EUR 0
}
