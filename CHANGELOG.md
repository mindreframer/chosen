# CHANGELOG

## [0.1.0] - 2025-12-28

### Added
- Initial release
- `Chosen` - Distributed singleton supervisor
- `Chosen.LockManager` - Shared connection pool for advisory locks
- Support for PostgreSQL advisory locks for cluster-wide singleton guarantees
- Configurable polling intervals for lock acquisition
- Multiple singleton support with unique lock names
- Multiple LockManager support for different databases
- Supervisor-like interface (`which_children/1`, `count_children/1`)
- Direct connection options support
- Comprehensive test suite
- Full documentation and examples
