test_convert_uses_a_rate_set_after_the_first_conversion() {
  rates_reset
  rates_convert 100 EUR
  converted_before_the_update="${REPLY}"
  rates_set EUR 200
  rates_convert 100 EUR
  assert_eq 125 "${converted_before_the_update}"
  assert_eq 200 "${REPLY}"
}
