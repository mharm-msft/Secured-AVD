# Contributing to Secured-AVD

Thanks for contributing. This repo enforces a few rules to keep the three IaC stacks
(ARM, Bicep, Terraform) honest with each other.

## The parameter parity contract

[`shared/parameters.reference.json`](shared/parameters.reference.json) is the
**single source of truth** for what parameters exist, their types, defaults, and which
are required.

**Rule**: Every parameter that exists in one stack must exist in the other two, with
the same name (camelCase), the same type, and the same semantic meaning. CI validates
this on every PR via the `parameter-parity` workflow.

If you add a new parameter:

1. Add it to `shared/parameters.reference.json` first.
2. Add it to `bicep/greenfield/main.bicep` and `bicep/cutover/main.bicep`.
3. Re-run `bicep build` against both Bicep entrypoints to regenerate the matching
   `arm/*/main.json`.
4. Add it to `terraform/greenfield/variables.tf` and `terraform/cutover/variables.tf`.
5. Update `shared/images.reference.json` if it relates to image selection.
6. Update docs that reference the variable.

## Authoring rules

- **Bicep is canonical.** Don't hand-edit `arm/**/*.json` — regenerate via `bicep build`.
- **Terraform uses AVM modules** where stable. See the module pinning in
  `terraform/*/main.tf`. Don't drop to raw `azurerm_` blocks unless AVM doesn't cover it.
- **No secrets in source.** Use `*.tfvars` (gitignored), Key Vault references in Bicep
  parameter files (`@Microsoft.KeyVault(...)`), or pipeline variable groups.
- **Documentation is part of the change.** New variables/modules need a paragraph in
  `docs/architecture.md` or the appropriate sub-doc.

## PR checklist

- [ ] Parameter parity verified (`shared/parameters.reference.json` updated)
- [ ] Bicep builds clean (`bicep build bicep/greenfield/main.bicep` and `bicep/cutover/main.bicep`)
- [ ] ARM regenerated (commit the regenerated JSON)
- [ ] `terraform fmt -recursive` clean
- [ ] `terraform validate` clean in both `terraform/greenfield` and `terraform/cutover`
- [ ] `conftest test ... --policy azure-policy-library-avm` passes (CI runs this)
- [ ] Docs updated

## Local checks before pushing

```powershell
# From repo root
bicep build bicep/greenfield/main.bicep
bicep build bicep/cutover/main.bicep
terraform -chdir=terraform/greenfield fmt -recursive
terraform -chdir=terraform/greenfield validate
terraform -chdir=terraform/cutover fmt -recursive
terraform -chdir=terraform/cutover validate
```
