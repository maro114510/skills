# Fixture source for check-rule-inventory tests

- The loop never reads or writes a label.
- Every merge request sends the reviewed SHA as its expected head.
- A third fix cycle parks the Issue.

func TestExpectedSHAMerge(t *testing.T) {}
