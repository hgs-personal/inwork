--!strict
--[[
	Minimal test procedure runner. A collection is a list of named functions; a test passes if
	its function returns without erroring, so tests use assert/error to fail. Tests run in order,
	after every system has started, and may yield. Tests with enabled = false are skipped.
]]

local Test = {}

export type TestCase = {
	name: string,
	enabled: boolean,
	run: () -> (),
}

--[[
	Run every enabled test in the collection and print a summary. Failures are reported with
	their traceback but do not stop the remaining tests. Returns the number of failed tests.
]]
function Test.run(collectionName: string, tests: { TestCase }): number
	local passed = 0
	local failed = 0
	local skipped = 0

	print(string.format("[Test] running %d %s tests", #tests, collectionName))

	for _, test in tests do
		if not test.enabled then
			skipped += 1
			print(string.format("[Test] SKIP %s", test.name))
			continue
		end

		local ok, err = xpcall(test.run, debug.traceback)
		if ok then
			passed += 1
			print(string.format("[Test] PASS %s", test.name))
		else
			failed += 1
			warn(string.format("[Test] FAIL %s\n%s", test.name, tostring(err)))
		end
	end

	local summary = string.format(
		"[Test] %s: %d passed, %d failed, %d skipped",
		collectionName,
		passed,
		failed,
		skipped
	)
	if failed > 0 then
		warn(summary)
	else
		print(summary)
	end

	return failed
end

return Test
