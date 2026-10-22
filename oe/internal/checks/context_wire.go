package checks

// Suite is the check suite a check run belongs to.
type Suite struct {
	DatabaseID *int64 `json:"databaseId"`
}

// Context is one node of a status check rollup: a CheckRun or a StatusContext. Fields the
// node does not carry are nil.
type Context struct {
	Typename   string  `json:"__typename"`
	Name       *string `json:"name"`
	Status     *string `json:"status"`
	Conclusion *string `json:"conclusion"`
	StartedAt  *string `json:"startedAt"`
	CheckSuite *Suite  `json:"checkSuite"`
	Context    *string `json:"context"`
	State      *string `json:"state"`
	CreatedAt  *string `json:"createdAt"`
}
