// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "erc721a-upgradeable/contracts/ERC721AUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "solady/src/utils/MerkleProofLib.sol";
import "solady/src/utils/ECDSA.sol";

error InvalidConfig();
error MintNotYetStarted();
error MintEnded();
error WalletUnauthorizedToMint();
error InsufficientEthSent();
error ExcessiveEthSent();
error Erc20BalanceTooLow();
error MaxSupplyExceeded();
error ListMaxSupplyExceeded();
error NumberOfMintsExceeded();
error MintingPaused();
error InvalidReferral();
error InvalidSignature();
error BalanceEmpty();
error TransferFailed();
error MaxBatchSizeExceeded();
error BurnToMintDisabled();
error NotTokenOwner();
error NotPlatform();
error NotOwner();
error NotApprovedToTransfer();
error InvalidAmountOfTokens();
error WrongPassword();
error LockedForever();
error Blacklisted();

//
// STRUCTS
//
struct Auth {
  bytes32 key;
  bytes32[] proof;
}

struct MintTier {
  uint16 numMints;
  uint16 mintDiscount; //BPS
}

struct Discount {
  uint16 affiliateDiscount; //BPS
  MintTier[] mintTiers;
}

struct ERC721Config {
  string baseUri;
  address affiliateSigner;
  address ownerAltPayout; // optional alternative address for owner withdrawals.
  address superAffiliatePayout; // optional super affiliate address, will receive half of platform fee if set.
  uint32 maxSupply;
  uint32 maxBatchSize;
  uint16 affiliateFee; //BPS
  uint16 platformFee; //BPS
  uint16 defaultRoyalty; //BPS
  Discount discounts;
}

struct Options {
  bool uriLocked;
  bool maxSupplyLocked;
  bool affiliateFeeLocked;
  bool discountsLocked;
  bool ownerAltPayoutLocked;
  bool royaltyEnforcementEnabled;
  bool royaltyEnforcementLocked;
}

struct DutchInvite {
  uint128 price;
  uint128 reservePrice;
  uint128 delta;
  uint32 start;
  uint32 end;
  uint32 limit;
  uint32 maxSupply;
  uint32 interval;
  uint32 unitSize; // mint 1 get x
  address tokenAddress;
  bool isBlacklist;
}

struct Invite {
  uint128 price;
  uint32 start;
  uint32 end;
  uint32 limit;
  uint32 maxSupply;
  uint32 unitSize; // mint 1 get x
  address tokenAddress;
  bool isBlacklist;
}

struct OwnerBalance {
  uint128 owner;
  uint128 platform;
}

struct BurnConfig {
  IERC721AUpgradeable archetype;
  address burnAddress;
  bool enabled;
  bool reversed; // side of the ratio (false=burn {ratio} get 1, true=burn 1 get {ratio})
  uint16 ratio;
  uint64 start;
  uint64 limit;
}

struct ValidationArgs {
  address owner;
  address affiliate;
  uint256 quantity;
  uint256 curSupply;
  uint256 listSupply;
}

address constant PLATFORM = 0x898E0a9661f03C6061951cC13d953967263776Ba;
address constant BATCH = 0x6Bc558A6DC48dEfa0e7022713c23D65Ab26e4Fa7;
uint16 constant MAXBPS = 5000; // max fee or discount is 50%

library ERC721PriceUtils {
  //
  // EVENTS
  //
  event Invited(bytes32 indexed key, bytes32 indexed cid);
  event Referral(address indexed affiliate, address token, uint128 wad, uint256 numMints);
  event Withdrawal(address indexed src, address token, uint128 wad);

  // calculate price based on affiliate usage and mint discounts
  function computePrice(
    DutchInvite storage invite,
    Discount storage discounts,
    uint256 numTokens,
    uint256 listSupply,
    bool affiliateUsed
  ) public view returns (uint256) {
    uint256 price = invite.price;
    uint256 cost;
    if (invite.interval > 0 && invite.delta > 0) {
      // Apply dutch pricing
      uint256 diff = (((block.timestamp - invite.start) / invite.interval) * invite.delta);
      if (price > invite.reservePrice) {
        if (diff > price - invite.reservePrice) {
          price = invite.reservePrice;
        } else {
          price = price - diff;
        }
      } else if (price < invite.reservePrice) {
        if (diff > invite.reservePrice - price) {
          price = invite.reservePrice;
        } else {
          price = price + diff;
        }
      }
      cost = price * numTokens;
    } else if (invite.interval == 0 && invite.delta > 0) {
      // Apply linear curve
      uint256 lastPrice = price + invite.delta * listSupply;
      cost = lastPrice * numTokens + (invite.delta * numTokens * (numTokens - 1)) / 2;
    } else {
      cost = price * numTokens;
    }

    if (affiliateUsed) {
      cost = cost - ((cost * discounts.affiliateDiscount) / 10000);
    }

    uint256 numMints = discounts.mintTiers.length;
    for (uint256 i; i < numMints; ) {
      uint256 tierNumMints = discounts.mintTiers[i].numMints;
      if (numTokens >= tierNumMints) {
        return cost - ((cost * discounts.mintTiers[i].mintDiscount) / 10000);
      }
      unchecked {
        ++i;
      }
    }
    return cost;
  }

  function validateMint(
    DutchInvite storage i,
    ERC721Config storage config,
    Auth calldata auth,
    mapping(address => mapping(bytes32 => uint256)) storage minted,
    bytes calldata signature,
    ValidationArgs memory args
  ) public view {
    address msgSender = _msgSender();
    if (args.affiliate != address(0)) {
      if (
        args.affiliate == PLATFORM || args.affiliate == args.owner || args.affiliate == msgSender
      ) {
        revert InvalidReferral();
      }
      validateAffiliate(args.affiliate, signature, config.affiliateSigner);
    }

    if (i.limit == 0) {
      revert MintingPaused();
    }

    if (!i.isBlacklist) {
      if (!verify(auth, i.tokenAddress, msgSender)) {
        revert WalletUnauthorizedToMint();
      }
    } else {
      if (verify(auth, i.tokenAddress, msgSender)) {
        revert Blacklisted();
      }
    }

    if (block.timestamp < i.start) {
      revert MintNotYetStarted();
    }

    if (i.end > i.start && block.timestamp > i.end) {
      revert MintEnded();
    }

    if (i.limit < i.maxSupply) {
      uint256 totalAfterMint = minted[msgSender][auth.key] + args.quantity;

      if (totalAfterMint > i.limit) {
        revert NumberOfMintsExceeded();
      }
    }

    if (i.maxSupply < config.maxSupply) {
      uint256 totalAfterMint = args.listSupply + args.quantity;
      if (totalAfterMint > i.maxSupply) {
        revert ListMaxSupplyExceeded();
      }
    }

    if (args.quantity > config.maxBatchSize) {
      revert MaxBatchSizeExceeded();
    }

    if ((args.curSupply + args.quantity) > config.maxSupply) {
      revert MaxSupplyExceeded();
    }

    uint256 cost = computePrice(
      i,
      config.discounts,
      args.quantity,
      args.listSupply,
      args.affiliate != address(0)
    );

    if (i.tokenAddress != address(0)) {
      IERC20 erc20Token = IERC20(i.tokenAddress);
      if (erc20Token.allowance(msgSender, address(this)) < cost) {
        revert NotApprovedToTransfer();
      }

      if (erc20Token.balanceOf(msgSender) < cost) {
        revert Erc20BalanceTooLow();
      }

      if (msg.value != 0) {
        revert ExcessiveEthSent();
      }
    } else {
      if (msg.value < cost) {
        revert InsufficientEthSent();
      }

      if (msg.value > cost) {
        revert ExcessiveEthSent();
      }
    }
  }

  function validateBurnToMint(
    ERC721Config storage config,
    BurnConfig storage burnConfig,
    uint256[] calldata tokenIds,
    uint256 curSupply,
    mapping(address => mapping(bytes32 => uint256)) storage minted
  ) public view {
    if (!burnConfig.enabled) {
      revert BurnToMintDisabled();
    }

    if (block.timestamp < burnConfig.start) {
      revert MintNotYetStarted();
    }

    // check if msgSender owns tokens and has correct approvals
    address msgSender = _msgSender();
    for (uint256 i; i < tokenIds.length; ) {
      if (burnConfig.archetype.ownerOf(tokenIds[i]) != msgSender) {
        revert NotTokenOwner();
      }
      unchecked {
        ++i;
      }
    }

    if (!burnConfig.archetype.isApprovedForAll(msgSender, address(this))) {
      revert NotApprovedToTransfer();
    }

    uint256 quantity;
    if (burnConfig.reversed) {
      quantity = tokenIds.length * burnConfig.ratio;
    } else {
      if (tokenIds.length % burnConfig.ratio != 0) {
        revert InvalidAmountOfTokens();
      }
      quantity = tokenIds.length / burnConfig.ratio;
    }

    if (quantity > config.maxBatchSize) {
      revert MaxBatchSizeExceeded();
    }

    if (burnConfig.limit < config.maxSupply) {
      uint256 totalAfterMint = minted[msgSender][bytes32("burn")] + quantity;

      if (totalAfterMint > burnConfig.limit) {
        revert NumberOfMintsExceeded();
      }
    }

    if ((curSupply + quantity) > config.maxSupply) {
      revert MaxSupplyExceeded();
    }
  }

  function updateBalances(
    DutchInvite storage i,
    ERC721Config storage config,
    mapping(address => OwnerBalance) storage _ownerBalance,
    mapping(address => mapping(address => uint128)) storage _affiliateBalance,
    uint256 listSupply,
    address affiliate,
    uint256 quantity
  ) public {
    address tokenAddress = i.tokenAddress;
    uint128 value = uint128(msg.value);
    if (tokenAddress != address(0)) {
      value = uint128(
        computePrice(i, config.discounts, quantity, listSupply, affiliate != address(0))
      );
    }

    uint128 affiliateWad;
    if (affiliate != address(0)) {
      affiliateWad = (value * config.affiliateFee) / 10000;
      _affiliateBalance[affiliate][tokenAddress] += affiliateWad;
      emit Referral(affiliate, tokenAddress, affiliateWad, quantity);
    }

    uint128 superAffiliateWad;
    if (config.superAffiliatePayout != address(0)) {
      superAffiliateWad = ((value * config.platformFee) / 2) / 10000;
      _affiliateBalance[config.superAffiliatePayout][tokenAddress] += superAffiliateWad;
    }

    OwnerBalance memory balance = _ownerBalance[tokenAddress];
    uint128 platformWad = ((value * config.platformFee) / 10000) - superAffiliateWad;
    uint128 ownerWad = value - affiliateWad - platformWad - superAffiliateWad;
    _ownerBalance[tokenAddress] = OwnerBalance({
      owner: balance.owner + ownerWad,
      platform: balance.platform + platformWad
    });

    if (tokenAddress != address(0)) {
      IERC20 erc20Token = IERC20(tokenAddress);
      erc20Token.transferFrom(_msgSender(), address(this), value);
    }
  }

  function withdrawTokens(
    ERC721Config storage config,
    mapping(address => OwnerBalance) storage _ownerBalance,
    mapping(address => mapping(address => uint128)) storage _affiliateBalance,
    address owner,
    address[] calldata tokens
  ) public {
    address msgSender = _msgSender();
    for (uint256 i; i < tokens.length; ) {
      address tokenAddress = tokens[i];
      uint128 wad;

      if (msgSender == owner || msgSender == config.ownerAltPayout || msgSender == PLATFORM) {
        OwnerBalance storage balance = _ownerBalance[tokenAddress];
        if (msgSender == owner || msgSender == config.ownerAltPayout) {
          wad = balance.owner;
          balance.owner = 0;
        } else {
          wad = balance.platform;
          balance.platform = 0;
        }
      } else {
        wad = _affiliateBalance[msgSender][tokenAddress];
        _affiliateBalance[msgSender][tokenAddress] = 0;
      }

      if (wad == 0) {
        revert BalanceEmpty();
      }

      if (tokenAddress == address(0)) {
        bool success = false;
        // send to ownerAltPayout if set and owner is withdrawing
        if (msgSender == owner && config.ownerAltPayout != address(0)) {
          (success, ) = payable(config.ownerAltPayout).call{value: wad}("");
        } else {
          (success, ) = msgSender.call{value: wad}("");
        }
        if (!success) {
          revert TransferFailed();
        }
      } else {
        IERC20 erc20Token = IERC20(tokenAddress);

        if (msgSender == owner && config.ownerAltPayout != address(0)) {
          erc20Token.transfer(config.ownerAltPayout, wad);
        } else {
          erc20Token.transfer(msgSender, wad);
        }
      }
      emit Withdrawal(msgSender, tokenAddress, wad);
      unchecked {
        ++i;
      }
    }
  }

  function validateAffiliate(
    address affiliate,
    bytes calldata signature,
    address affiliateSigner
  ) public view {
    bytes32 signedMessagehash = ECDSA.toEthSignedMessageHash(
      keccak256(abi.encodePacked(affiliate))
    );
    address signer = ECDSA.recover(signedMessagehash, signature);

    if (signer != affiliateSigner) {
      revert InvalidSignature();
    }
  }

  function verify(
    Auth calldata auth,
    address tokenAddress,
    address account
  ) public pure returns (bool) {
    // keys 0-255 and tokenAddress are public
    if (uint256(auth.key) <= 0xff || auth.key == keccak256(abi.encodePacked(tokenAddress))) {
      return true;
    }

    return MerkleProofLib.verify(auth.proof, auth.key, keccak256(abi.encodePacked(account)));
  }

  function _msgSender() internal view returns (address) {
    return msg.sender == BATCH ? tx.origin : msg.sender;
  }
}
