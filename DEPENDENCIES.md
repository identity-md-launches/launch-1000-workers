# Vendored dependencies

Only source files and licenses are vendored. No build-time network access, git submodules, install hooks, or generated package directories are required.

| Dependency | Pinned release | Included files | License |
| --- | --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2) | `v5.0.2` | ERC20, IERC20, IERC20Metadata, Context, IERC6093 errors, Ownable, Ownable2Step and their license | MIT: `lib/openzeppelin-contracts/LICENSE` |
| [forge-std](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | `v1.9.7` | Complete `src/` tree for test utilities, with both licenses | Apache-2.0 OR MIT: `lib/forge-std/LICENSE-APACHE`, `lib/forge-std/LICENSE-MIT` |

OpenZeppelin files are unmodified upstream release sources. The forge-std sources are from the pinned release, with formatting-only changes in `StdAssertions.sol`, `StdJson.sol`, `StdToml.sol`, `Vm.sol`, `console.sol`, `interfaces/IERC7540.sol` and `interfaces/IMulticall3.sol` under `lib/forge-std/src/`. These seven copies were compared with the v1.9.7 upstream files and match after removing spaces, tabs and line endings; no semantic changes were made. forge-std is used only by the tests.

SHA-256 hashes of the **vendored bytes**, including their formatting, are recorded in `DEPENDENCIES.sha256`; verify using `sha256sum --check DEPENDENCIES.sha256`. These are not upstream byte hashes for the seven reformatted files. Foundry and solc binaries are not vendored: the verification environment provides the pinned compiler.
