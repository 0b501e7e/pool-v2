// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { IMapleProxyFactory, MapleProxyFactory } from "../../modules/maple-proxy-factory/contracts/MapleProxyFactory.sol";

import { IGlobalsLike } from "../interfaces/Interfaces.sol";

contract LoanManagerFactory is MapleProxyFactory {

    constructor(address globals_) MapleProxyFactory(globals_) { }

    function createInstance(bytes calldata arguments_, bytes32 salt_) override(MapleProxyFactory) public returns (address instance_) {
        require(IGlobalsLike(mapleGlobals).isPoolDeployer(msg.sender), "LMF:CI:NOT_DEPLOYER");

        isInstance[instance_ = super.createInstance(arguments_, salt_)] = true;
    }

}
