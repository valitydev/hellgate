# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hellgate is the core payment processing state machine service. It orchestrates invoice lifecycle, payment processing, refunds, chargebacks, and provider routing using event sourcing (Progressor/Machinegun backends) and Woody/Thrift RPC.

## Build & Development Commands

```bash
make compile                       # Build the project
make test                          # Run eunit + common test
make eunit                         # Unit tests only
make common-test                   # All Common Test suites
make common-test.invoice           # Single suite (hg_invoice_tests_SUITE)
make common-test.invoice CT_CASE=some_case  # Single test case
make dialyze                       # Dialyzer type checking (runs as test profile)
make lint                          # Elvis code style checks
make format                        # Auto-format with erlfmt
make check-format                  # Verify formatting
make xref                          # Cross-reference analysis
make release                       # Production release

# Docker-based (full dependency stack):
make wdeps-test                    # Tests with Postgres, DMT, party-management, etc.
make wdeps-common-test.invoice     # Single suite with deps
make wdeps-common-test.invoice CT_CASE=some_case  # Single case with deps
```

Common Test suites require external services (Postgres, DMT, party-management, bender, limiter, shumway, cubasty). Use `wdeps-` prefix to run them with Docker Compose.

Suite naming pattern: `make common-test.X` maps to `apps/hellgate/test/hg_X_tests_SUITE.erl`.

## Architecture

### OTP Applications (in `apps/`)

- **hellgate** - Main app: invoice/payment state machines, routing, limits, accounting, provider proxying
- **hg_proto** - Thrift service definitions and protocol wrappers
- **hg_client** - Woody client library for invoicing/templating APIs
- **hg_progressor** - Progressor backend integration with OpenTelemetry tracing
- **routing** - Payment routing logic (provider/terminal selection, fault detection)

### Core State Machine Hierarchy

`hg_invoice` (invoice lifecycle) -> `hg_invoice_payment` (payment processing) -> `hg_invoice_payment_refund`, `hg_invoice_payment_chargeback`

All machines are event-sourced via `hg_machine` behavior, backed by Progressor (default) or Machinegun.

### Key Modules

- `hg_machine.erl` - Machine abstraction behavior (signal/call handling, event history)
- `hg_invoice.erl` - Invoice state machine
- `hg_invoice_payment.erl` - Payment state machine (largest module: sessions, retries, routing, capture, refund, chargeback)
- `hg_routing.erl` (in routing app) - Route gathering, provider selection, fault detector integration
- `hg_limiter.erl` - Turnover limit enforcement (hold/commit/rollback)
- `hg_cashflow.erl` - Cash flow computation and finalization
- `hg_session.erl` - Provider interaction session management
- `hg_inspector.erl` - Risk scoring and blacklist checking

### External Service Dependencies

Party-management (merchant config), DMT (domain/business rules), Bender (ID generation), Limiter/Liminator (rate limits), Shumway (accounting), Cubasty (customer storage), Fault Detector (provider availability).

## Erlang Conventions

- **Compiler flags**: `warnings_as_errors`, `warn_missing_spec` - all exported functions need typespecs
- **Formatter**: erlfmt, 120 char width. Run `make format` before committing
- **Linter**: Elvis with strict rules - no `if` expressions, max nesting level 4, max arity 10
- **Dialyzer**: Runs under `test` profile (`rebar3 as test dialyzer`)
- **Validation sequence**: `make compile && make format && make lint && make dialyze`

## Testing

Test helpers live alongside suites in `apps/hellgate/test/`:
- `hg_ct_helper.erl` - CT setup, service startup, context/config creation
- `hg_ct_fixture.erl` - Domain fixture generation
- `hg_invoice_helper.erl` - Invoice/payment test utilities
- `hg_dummy_provider.erl` - Mock payment provider
- `hg_dummy_inspector.erl` - Mock risk inspector
