import Foundation

runDomainChecks()
runHostsChecks()
runScheduleChecks()
runConfigChecks()
runStorageChecks()
runHelperChecks()
await runControllerChecks()

print("\n\(Harness.checks - Harness.failures)/\(Harness.checks) checks passed")
exit(Harness.failures == 0 ? 0 : 1)
