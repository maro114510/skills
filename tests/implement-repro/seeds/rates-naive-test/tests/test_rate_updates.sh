test_convert_uses_the_rate_set_by_rates_set() {
  rates_reset
  rates_set EUR 200
  rates_convert 100 EUR
  assert_eq 200 "${REPLY}"
}
