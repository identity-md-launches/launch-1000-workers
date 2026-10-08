# Vendored dependencies

Only source files and licenses are vendored. No build-time network access, git submodules, install hooks, or generated package directories are required.

| Dependency | Pinned release | Included files | License |
| --- | --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2) | `v5.0.2` | ERC20, IERC20, IERC20Metadata, Context, IERC6093 errors, Ownable, Ownable2Step and their license | MIT: `lib/openzeppelin-contracts/LICENSE` |
| [forge-std](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | `v1.9.7` | Complete `src/` tree for test utilities, with both licenses | Apache-2.0 OR MIT: `lib/forge-std/LICENSE-APACHE`, `lib/forge-std/LICENSE-MIT` |

The library files are unmodified upstream release sources. Their SHA-256 hashes are recorded in `DEPENDENCIES.sha256`; verify using `sha256sum --check DEPENDENCIES.sha256`. Foundry and solc binaries are not vendored: the verification environment provides the pinned compiler.
