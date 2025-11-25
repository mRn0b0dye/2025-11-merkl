# Merkl audit details
- Total Prize Pool: $18,000 in USDC
    - HM awards: up to $14,400 in USDC
        - If no valid Highs or Mediums are found, the HM pool is $0
    - QA awards: $600 in USDC
    - Judge awards: $2,500 in USDC
    - Scout awards: $500 in USDC
- [Read our guidelines for more details](https://docs.code4rena.com/competitions)
- Starts November 25, 2025 20:00 UTC
- Ends December 1, 2025 20:00 UTC

### ❗ Important notes for wardens
1. A coded, runnable PoC is required for all High/Medium submissions to this audit. 
    - This repo includes a basic template to run the test suite.
    - PoCs must use the test suite provided in this repo.
    - Your submission will be marked as Insufficient if the POC is not runnable and working with the provided test suite.
    - Exception: PoC is optional (though recommended) for wardens with signal ≥ 0.68.
1. Judging phase risk adjustments (upgrades/downgrades):
    - High- or Medium-risk submissions downgraded by the judge to Low-risk (QA) will be ineligible for awards.
    - Upgrading a Low-risk finding from a QA report to a Medium- or High-risk finding is not supported.
    - As such, wardens are encouraged to select the appropriate risk level carefully during the submission phase.

## V12 findings

[V12](https://v12.zellic.io/) is [Zellic](https://zellic.io)'s in-house AI auditing tool. It is the only autonomous Solidity auditor that [reliably finds Highs and Criticals](https://www.zellic.io/blog/introducing-v12/). All issues found by V12 will be judged as out of scope and ineligible for awards.

[V12 findings can be viewed here.](https://github.com/code-423n4/2025-11-merkl/blob/main/2025_11_merkl_v12.md)  

## Publicly known issues

_Anything included in this section is considered a publicly known issue and is therefore ineligible for awards._

Merkl operates as a centralized solution. Therefore, any issues related to the contract owner's administrative access should be considered out of scope.
Additionally, the following assumptions underpin the system's security model:

- The dispute resolution mechanism functions as intended
- Active monitoring bots continuously verify reward distributions through Merkl

We acknowledge a known risk: When users designate a smart contract as their reward recipient and pass data to it, their rewards are potentially vulnerable if:

- The recipient contract is misconfigured or malicious
- The user submits incorrect parameters (such as executing a swap without slippage protection)

In such cases, the recipient contract could redirect or capture the user's rewards.

# Overview

Merkl is a DeFi incentive platform that **connects liquidity providers with protocols** looking to boost activity and engagement.

- For Protocols: Launch, manage, and customize growth campaigns to attract liquidity, track user engagement, and distribute incentives without the usual operational burden.

- For Users: Earn rewards or points by participating in incentive campaigns.

At its core, Merkl operates on an offchain engine that processes both onchain and offchain data to compute rewards and points for campaigns.

## Links

- **Previous audits:**  https://code4rena.com/reports/2023-06-angle
- **Documentation:** https://docs.merkl.xyz
- **Website:** https://merkl.xyz/
- **X/Twitter:** https://x.com/merkl_xyz

---

# Scope

### Files in scope


| File   | nSLOC |
| ------ | ----- |
|[contracts/DistributionCreator.sol](https://github.com/code-423n4/2025-11-merkl/blob/main/contracts/DistributionCreator.sol)| 333 |
|[contracts/Distributor.sol](https://github.com/code-423n4/2025-11-merkl/blob/main/contracts/Distributor.sol)| 271 |
|**Totals**| **604** |

*For a machine-readable version, see [scope.txt](https://github.com/code-423n4/2025-11-merkl/blob/main/scope.txt)*

### Files out of scope

| File         |
| ------------ |
|[contracts/AccessControlManager.sol](https://github.com/code-423n4/2025-11-merkl/blob/main/contracts/AccessControlManager.sol)|
|[contracts/Disputer.sol](https://github.com/code-423n4/2025-11-merkl/blob/main/contracts/Disputer.sol)|
|[contracts/DistributionCreatorWithDistributions.sol](https://github.com/code-423n4/2025-11-merkl/blob/main/contracts/DistributionCreatorWithDistributions.sol)|
|[contracts/ReferralRegistry.sol](https://github.com/code-423n4/2025-11-merkl/blob/main/contracts/ReferralRegistry.sol)|
|[contracts/interfaces/\*\*.\*\*](https://github.com/code-423n4/2025-11-merkl/tree/main/contracts/interfaces)|
|[contracts/mock/\*\*.\*\*](https://github.com/code-423n4/2025-11-merkl/tree/main/contracts/mock)|
|[contracts/partners/middleman/\*\*.\*\*](https://github.com/code-423n4/2025-11-merkl/tree/main/contracts/partners/middleman)|
|[contracts/partners/tokenWrappers/\*\*.\*\*](https://github.com/code-423n4/2025-11-merkl/tree/main/contracts/partners/tokenWrappers)|
|[contracts/struct/\*\*.\*\*](https://github.com/code-423n4/2025-11-merkl/tree/main/contracts/struct)|
|[contracts/utils/\*\*.\*\*](https://github.com/code-423n4/2025-11-merkl/tree/main/contracts/utils)|
|[scripts/\*\*.\*\*](https://github.com/code-423n4/2025-11-merkl/tree/main/scripts)|
|[test/\*\*.\*\*](https://github.com/code-423n4/2025-11-merkl/tree/main/test)|
| Totals: 60 |

*For a machine-readable version, see [out_of_scope.txt](https://github.com/code-423n4/2025-11-merkl/blob/main/out_of_scope.txt)*

# Additional context

## Areas of concern (where to focus for bugs)

Primary Security Concerns:

### 1. Campaign Pre-Deposit Protection

Can an address exploit or access funds pre-deposited by another address without authorization?

### 2. Reward Claim Integrity

Do rewards consistently reach their intended recipient through all claim paths (the claimant's address, a recipient specified in the call parameters, or a user-defined default recipient)?

### 3. Unauthorized Access and Fund Theft

Any scenario enabling unauthorized assumption of user roles or theft of funds constitutes a valid issue, including:

- Pre-deposited funds in the distributionCreator contract
- Idle funds in the distributor contract


## Main invariants

### Guardian Restrictions
The Guardian role must not have the ability to steal user funds or perform actions that result in fund reallocation.

### Reward Finality
Once rewards are earned and recorded in a Merkle root, they are immutably assigned to the recipient. These rewards cannot be revoked or redirected within the current Merkle root, except through:
- An explicit reallocation by authorized parties
- Token recovery executed by the admin address

### Campaign Creator Autonomy

Campaign creators retain full control over:
- End-to-end campaign management
- Their pre-deposited funds
- The ability to recover ownership of their funds at any time
- They can revoke any role or allowance they give at anytime

## All trusted roles in the protocol

The contracts include three main trusted roles:

| Role                                | Description                       |
| --------------------------------------- | ---------------------------- |
| Governor                          | - Operated via multisignature wallet<br>- Possesses administrative rights over the distribution contracts and creator                |
| Guardian                             | - May be held by EOAs<br>- Responsible for operational tasks such as whitelisting of tokens and toggling operator permissions                       |
| Updater Address | - Authorized to update Merkle roots<br>- May be EOAs as a dispute period exists as a safeguard to prevent malicious root updates before they are finalized |

## Running tests

### Prerequisites

The repository utilizes the `foundry` (`forge`) toolkit to compile its contracts, and contains several dependencies through `foundry` that will be automatically installed whenever a `forge` command is issued.

The compilation instructions were evaluated with the following toolkit versions:

- forge: `1.4.4-stable`
- NodeJS: `12.13.0` (any should work)

### Building

After installing all `npm` dependencies through the `npm i` command, the traditional `forge` build command will install the foundry-specific dependencies and build the project:

```sh
forge build
```

### Tests

The following command can be issued to execute all tests within the repository:

```sh
forge test
``` 

## Creating a PoC

The project is composed of two core contracts; a `DistributionCreator` and a `Distribution` contract.

The `C4PoC.t.sol` file contained within the `test/c4` subpath will setup a `DistributionCreator` that permits wardens to demonstrate vulnerabilities pertaining to both the creator and its distribution instances. 

For a submission to be considered valid, the test case **should execute successfully** via the following command:

```bash 
forge test --match-test submissionValidity
```

PoCs meant to demonstrate a reverting transaction **must utilize the special `expect` utility functions `forge` exposes**. Failure to do so may result in an invalidation of the submission. 

All PoCs must adhere to the following guidelines:

- The PoC should execute successfully
- The PoC must not mock any contract-initiated calls
- The PoC must not utilize any mock contracts in place of actual in-scope implementations


## Miscellaneous

Employees of Merkl and employees' family members are ineligible to participate in this audit.

Code4rena's rules cannot be overridden by the contents of this README. In case of doubt, please check with C4 staff.
