// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LaunchpadERC721, ERC721Config} from "./LaunchpadERC721.sol";
import {LaunchpadERC1155, ERC1155Config} from "./LaunchpadERC1155.sol";
import {ClonesUpgradeable} from "./lib/ClonesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract Factory is OwnableUpgradeable {
  event CollectionAdded(
    address indexed sender,
    address indexed receiver,
    address collection,
    string standard
  );
  address public erc721Imp;
  address public erc1155Imp;

  function initialize(address _erc721Imp, address _erc1155Imp) public initializer {
    erc721Imp = _erc721Imp;
    erc1155Imp = _erc1155Imp;
    __Ownable_init(msg.sender);
  }

  /// @notice config is a struct in the shape of {string placeholder; string base; uint64 supply; bool permanent;}
  function createCollectionERC721(
    address receiver,
    string memory name,
    string memory symbol,
    ERC721Config calldata config
  ) external payable returns (address) {
    address clone = ClonesUpgradeable.clone(erc721Imp);
    LaunchpadERC721 token = LaunchpadERC721(clone);
    token.initialize(name, symbol, config, receiver);

    token.transferOwnership(receiver);
    if (msg.value > 0) {
      (bool sent, ) = payable(receiver).call{value: msg.value}("");
      require(sent, "1");
    }
    emit CollectionAdded(_msgSender(), receiver, address(token), "ERC721A");
    return address(token);
  }

  /// @notice config is a struct in the shape of {string placeholder; string base; uint64 supply; bool permanent;}
  function createCollectionERC1155(
    address receiver,
    string memory name,
    string memory symbol,
    ERC1155Config calldata config
  ) external payable returns (address) {
    address clone = ClonesUpgradeable.clone(erc1155Imp);
    LaunchpadERC1155 token = LaunchpadERC1155(clone);
    token.initialize(name, symbol, config, receiver);

    token.transferOwnership(receiver);
    if (msg.value > 0) {
      (bool sent, ) = payable(receiver).call{value: msg.value}("");
      require(sent, "1");
    }
    emit CollectionAdded(_msgSender(), receiver, address(token), "ERC1155");
    return address(token);
  }

  function setERC721Implement(address _implement) public onlyOwner {
    erc721Imp = _implement;
  }

  function setERC1155Implment(address _implement) public onlyOwner {
    erc1155Imp = _implement;
  }
}
