# validate-iam

Diagnoses whether an AWS account and EKS management cluster have the IAM
configuration required by Palette VerteX. It supports static AWS credentials,
STS, and EKS Pod Identity and never modifies IAM or the cluster.

## Usage

```bash
cd spectro-tools/validate-iam
cp ../config/common-config.sh.tmpl ../config/common-config.sh  # first use only

./validate-iam.sh
./validate-iam.sh secret
./validate-iam.sh sts
./validate-iam.sh pod-identity
```

Select a trusted per-run shell override when needed:

```bash
CONFIG_FILE=/secure/path/production.conf ./validate-iam.sh pod-identity
```

Render the reusable CAPA `iam:PassRole` policy separately:

```bash
./render-capa-policy.sh > /secure/path/capa-passrole-policy.json
```

## Options

| Argument or variable | Description |
| --- | --- |
| `secret` | Validate the current IAM user represented by Palette's static access key. |
| `sts` | Validate the configured Palette role and a tagged `sts:AssumeRole` session. |
| `pod-identity` | Validate Palette, Hubble, and identity roles, associations, addon, and runtime injection. |
| `CONFIG_FILE` | Optional trusted shell file sourced after common-config. |

The single positional mode overrides `AUTH_MODE`. With no positional argument,
the configured mode is used. Unknown modes or more than one argument are
rejected.

## Requirements

- Bash, AWS CLI, and `jq`.
- Working AWS credentials and a configured region.
- Permission to inspect IAM roles, simulate their policies, inspect EKS, and
  assume roles used by the selected mode. Policy simulation requires
  `iam:SimulatePrincipalPolicy`.
- Pod Identity mode: `kubectl` and access to the management cluster for live
  Kubernetes checks. Checks that cannot run are reported clearly.

Supported partitions are `aws`, `aws-us-gov`, `aws-iso`, and `aws-iso-b`.

## Configuration

Edit the `validate-iam` section of `../config/common-config.sh`:

```bash
: "${AWS_PROFILE=}"
: "${PARTITION=aws}"
: "${AUTH_MODE=pod-identity}"
: "${CLUSTER_NAME=}"
: "${ACCOUNT_ID=}"
: "${ROLE_ID_SUFFIX=}"
: "${DEPLOYER_ROLE_NAME=SpectroCloudPaletteRole${ROLE_ID_SUFFIX:+-${ROLE_ID_SUFFIX}}}"
: "${HUBBLE_ROLE_NAME=SpectroCloudHubbleRole${ROLE_ID_SUFFIX:+-${ROLE_ID_SUFFIX}}}"
: "${IDENTITY_ROLE_NAME=SpectroCloudIdentityRole${ROLE_ID_SUFFIX:+-${ROLE_ID_SUFFIX}}}"
: "${PERMISSION_PROFILE=minimum-dynamic}"
: "${PLACEMENT_MODE=dynamic}"
: "${TARGET_ACCOUNT_ID=}"
```

| Variable | Purpose |
| --- | --- |
| `AWS_PROFILE` | Optional AWS CLI profile; empty uses the standard credential chain. |
| `PARTITION` | AWS partition used to build and validate ARNs. |
| `AUTH_MODE` | `secret`, `sts`, or `pod-identity`. |
| `CLUSTER_NAME` | EKS management cluster; empty skips live EKS checks. |
| `ACCOUNT_ID` | Role-owning account; empty resolves it with STS. |
| `ROLE_ID_SUFFIX` | Optional shared suffix for the three derived role defaults. |
| `DEPLOYER_ROLE_NAME` | Palette/cloud-account role; corresponds to `PALETTE_ROLE_NAME` in `eks-deploy`. |
| `HUBBLE_ROLE_NAME` | Hubble role used by Pod Identity. |
| `IDENTITY_ROLE_NAME` | Palette identity role used by Pod Identity. |
| `PERMISSION_PROFILE` | `core`, `minimum-dynamic`, or `minimum-static`. |
| `PLACEMENT_MODE` | `dynamic` or `static`; must match a minimum profile's suffix. |
| `TARGET_ACCOUNT_ID` | Optional cross-account validation target. |

Environment values take precedence over common-config defaults. An explicit
`CONFIG_FILE` is sourced afterward and is authoritative; only use files you
trust. The positional authentication mode has final precedence.

For GovCloud, use `PARTITION=aws-us-gov` with credentials and a region in that
partition. Confirm the selected identity before validation:

```bash
source ../config/common-config.sh
[[ -z "$AWS_PROFILE" ]] || export AWS_PROFILE
aws sts get-caller-identity
aws configure get region
```

## Behavior

Every run checks credentials, caller identity, partition-correct ARNs, selected
EC2/EKS/IAM permissions, OIDC management, CAPA role naming/existence, and
optional cross-account access. Mode-specific checks are:

| Mode | Additional validation |
| --- | --- |
| `secret` | Requires a direct IAM-user caller and skips role assumption and Pod Identity checks. |
| `sts` | Simulates the Palette role and performs tagged role assumption. |
| `pod-identity` | Validates role trust, role policies, Pod Identity agent, service-account associations, Kubernetes configuration, and runtime injection. |

`PERMISSION_PROFILE=core` checks Palette-role add-on describe, create, delete,
and update permissions. Minimum profiles check only the add-on actions assigned
to the Palette role in Spectro's minimum model, preventing false failures for
permissions assigned to Hubble or controller roles.

Most Pod Identity checks are valid before VerteX is installed. Runtime checks
inspect matching Hubble and identity pods only when they exist; otherwise they
report `WARN` and skip. Once a matching pod exists, missing
`AWS_CONTAINER_CREDENTIALS_FULL_URI` or
`AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` is a failure.

AWS cluster checks use `CLUSTER_NAME`; Kubernetes checks use the current
kubeconfig context and never switch it. Confirm they identify the same cluster:

```bash
kubectl config current-context
kubectl cluster-info
```

## Policies

Reference policies are stored under `policies/`. They are never applied
automatically. Review and adapt them for the target partition, account, role
names, and least-privilege requirements.

The CAPA policy template is account-neutral. `render-capa-policy.sh` replaces
its role resource with the configured partition and account. To attach the
reviewed output:

```bash
aws iam put-role-policy \
  --role-name "$DEPLOYER_ROLE_NAME" \
  --policy-name PaletteCAPAPassRole \
  --policy-document file:///secure/path/capa-passrole-policy.json
```

## Results and remediation

Checks report `PASS`, `WARN`, or `FAIL`. Every failure includes a targeted
`FIX` describing the relevant permission, role, resource, command, or
configuration change.

- `implicitDeny`: no applicable allow statement grants the action.
- `explicitDeny`: a policy explicitly denies the action.
- `error`: simulation access, role lookup, credentials, or AWS configuration
  prevented a reliable result.

If a permission remains denied after attaching an allow policy, inspect IAM
permissions boundaries, session policies, and AWS Organizations SCPs. IAM
simulation does not reproduce every live authorization decision.

The script exits `0` when required checks pass and `1` for missing
prerequisites, invalid configuration, or failed checks. Warnings do not change
the exit status.

## Safety

The validator is diagnostic: it does not create roles, attach policies, install
addons, or modify Kubernetes. Output can contain account IDs, role ARNs,
cluster names, OIDC issuers, and Pod Identity associations; handle it as
sensitive operational data.
