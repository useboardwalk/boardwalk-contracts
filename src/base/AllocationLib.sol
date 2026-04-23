// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

/// @title AllocationLib
/// @notice Shared token-allocation math used by LaunchFactory and PresaleManager. Liquidity always
///         equals presale; LP incentive is 20% of the remainder; issuer vesting is the rest.
library AllocationLib {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant LP_INCENTIVE_PERCENT = 20;

    function compute(
        uint256 totalSupply,
        uint256 presalePercent
    )
        internal
        pure
        returns (uint256 presaleTokens, uint256 liquidityTokens, uint256 lpIncentiveTokens, uint256 issuerVestingTokens)
    {
        presaleTokens = totalSupply * presalePercent / BPS_DENOMINATOR;
        liquidityTokens = presaleTokens;
        uint256 vestingTotal = totalSupply - presaleTokens - liquidityTokens;
        lpIncentiveTokens = vestingTotal * LP_INCENTIVE_PERCENT / 100;
        issuerVestingTokens = vestingTotal - lpIncentiveTokens;
    }

    /// @dev Last entry receives the remainder so BPS rounding never loses dust.
    function splitByBps(
        uint256 total,
        uint256[] memory bps
    ) internal pure returns (uint256[] memory amounts) {
        uint256 len = bps.length;
        amounts = new uint256[](len);
        if (len == 0) return amounts;
        uint256 distributed;
        for (uint256 i = 0; i < len - 1;) {
            amounts[i] = total * bps[i] / BPS_DENOMINATOR;
            distributed += amounts[i];
            unchecked {
                ++i;
            }
        }
        amounts[len - 1] = total - distributed;
    }
}
