# Local VM via Terraform (Multipass)

This repo supports local VM creation with Terraform using Multipass.

## One command

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\tf_vm.ps1 -Action apply -AutoApprove
```

The script will try to auto-install dependencies via winget:

- `Canonical.Multipass`
- `Hashicorp.Terraform`
- fallback: `OpenTofu.Tofu` (if Terraform download is unavailable)

## Notes

- If `terraform.tfvars` is missing, the script creates it from `infra/terraform/terraform.tfvars.example`.
- Script auto-fixes legacy cloud migration artifacts:
  - rewrites old `terraform.auto.tfvars` keys from Timeweb format to local VM format;
  - archives old `terraform.tfstate` that references cloud/legacy providers.
- Script auto-detects local SSH public key and writes absolute Windows path to `terraform.tfvars`.
- Script writes `multipass_driver` to `terraform.tfvars` (`hyperv`, `virtualbox`, or `auto`).
- If winget cannot install Terraform in your network, script falls back to `tofu`.
- Terraform config is providerless (`terraform_data` + local-exec), so `tofu` does not need provider downloads from OpenTofu registry.
- If you see `cannot connect to the multipass socket`, open PowerShell as Administrator and verify:
  - `"C:\Program Files\Multipass\bin\multipass.exe" list`
  - If it still fails, restart the `Multipass` service and sign out/in.
- If launch fails with VirtualBox/UUID errors, check driver:
  - `"C:\Program Files\Multipass\bin\multipass.exe" get local.driver`
  - install VirtualBox for `virtualbox`, or switch to Hyper-V:
    - `"C:\Program Files\Multipass\bin\multipass.exe" set local.driver=hyperv`

## Destroy local VM

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\tf_vm.ps1 -Action destroy -AutoApprove
```
