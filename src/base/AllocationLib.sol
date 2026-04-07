// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

/// @title AllocationLib - Token allocation math for launch creation and liquidity seeding
library AllocationLib {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant LP_INCENTIVE_PERCENT = 20;

    /// @notice Compute token allocation buckets from total supply and presale percentage
    /// @param totalSupply The fixed token total supply
    /// @param presalePercent Presale percentage in BPS (e.g. 3000 = 30%)
    /// @return presaleTokens Tokens for presale participants
    /// @return liquidityTokens Tokens paired with raise token for LP (always equals presaleTokens)
    /// @return lpIncentiveTokens Tokens for LP staking rewards (20% of vesting bucket)
    /// @return issuerVestingTokens Tokens for issuer vesting (remainder of vesting bucket)
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

    /// @notice Split a total amount by BPS shares with remainder to last recipient
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
