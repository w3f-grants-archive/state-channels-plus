pragma solidity ^0.8.8;

import "./StateChannelCommon.sol";
import "./DisputeManagerFacet.sol";
import "./StateChannelUtilLibrary.sol";
import "../StateChannelManagerInterface.sol";

abstract contract AStateChannelManagerProxy is
    StateChannelManagerInterface,
    StateChannelCommon
{
    DisputeManagerFacet disputeManagerFacet;

    constructor(
        address _stateMachineImplementation,
        address _disputeManagerFacet
    ) {
        stateMachineImplementation = AStateMachine(_stateMachineImplementation);
        disputeManagerFacet = DisputeManagerFacet(_disputeManagerFacet);
        p2pTime = 15;
        agreementTime = 5;
        chainFallbackTime = 30;
        challengeTime = 60;
    }

    function applySlashesToStateMachine(
        bytes memory encodedState,
        address[] memory slashedParticipants
    )
        public
        onlySelf
        returns (
            bytes memory encodedModifiedState,
            ProcessExit[] memory,
            uint successCnt
        )
    {
        return _applySlashesToStateMachine(encodedState, slashedParticipants);
    }

    function removeParticipantsFromStateMachine(
        bytes memory encodedState,
        address[] memory participants
    )
        public
        onlySelf
        returns (
            bytes memory encodedModifiedState,
            ProcessExit[] memory,
            uint successCnt
        )
    {
        return _removeParticipantsFromStateMachine(encodedState, participants);
    }

    function getLatestState(
        bytes32 channelId
    ) public view override returns (bytes memory) {
        return encodedStates[channelId][latestFork[channelId]];
    }

    function _applySlashesToStateMachine(
        bytes memory encodedState,
        address[] memory slashedParticipants
    )
        internal
        returns (
            bytes memory encodedModifiedState,
            ProcessExit[] memory,
            uint successCnt
        )
    {
        ProcessExit[] memory processExits = new ProcessExit[](
            slashedParticipants.length
        );
        uint successCnt = 0;
        stateMachineImplementation.setState(encodedState);
        for (uint i = 0; i < slashedParticipants.length; i++) {
            bool success;
            (success, processExits[successCnt]) = stateMachineImplementation
                .slashParticipant(slashedParticipants[i]);
            // require(success, "Slash failed");
            if (success) successCnt++;
        }
        return (
            stateMachineImplementation.getState(),
            processExits,
            successCnt
        );
    }

    function _removeParticipantsFromStateMachine(
        bytes memory encodedState,
        address[] memory participants
    )
        internal
        returns (
            bytes memory encodedModifiedState,
            ProcessExit[] memory,
            uint successCnt
        )
    {
        ProcessExit[] memory processExits = new ProcessExit[](
            participants.length
        );
        uint successCnt = 0;
        stateMachineImplementation.setState(encodedState);
        for (uint i = 0; i < participants.length; i++) {
            bool success;
            (success, processExits[successCnt]) = stateMachineImplementation
                .removeParticipant(participants[i]);
            // require(success, "Remove failed");
            if (success) successCnt++;
        }
        return (
            stateMachineImplementation.getState(),
            processExits,
            successCnt
        );
    }

    /**
     * This implementation covers a MFS (minimal feature set) funded by the Web3 Foundation.
     * Posting calldata is currenlty unefficient since the dispute mechanism only has a minimal feature set (MFS)
     * In the Full feature set (FFS) this will post the calldata and modify a single storage slot
     */
    function postBlockCalldata(SignedBlock memory signedBlock) public override {
        //check siganture
        address[] memory addressesInThreshold = new address[](1);
        addressesInThreshold[0] = msg.sender;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = bytes(signedBlock.signature);
        (bool succeeds, ) = StateChannelUtilLibrary.verifyThresholdSigned(
            addressesInThreshold,
            bytes(signedBlock.encodedBlock),
            signatures
        );

        require(
            succeeds,
            "AStateChannelManager: postBlockCalldata signature invalid"
        );

        //Decode block;
        Block memory _block = abi.decode(
            bytes(signedBlock.encodedBlock),
            (Block)
        );
        //Check if sender is participant - needed since chainTime will be used as block/tx time in disputes
        require(
            msg.sender == _block.transaction.header.participant,
            "AStateChannelManager: postBlockCalldata sender must be participant"
        );
        //Check timestamp within range:
        require(
            _block.transaction.header.timestamp >=
                block.timestamp - p2pTime - agreementTime - chainFallbackTime,
            "AStateChannelManager: postBlockCalldata timestamp too old"
        );
        require(
            _block.transaction.header.timestamp <= block.timestamp,
            "AStateChannelManager: postBlockCalldata timestamp too new"
        );
        bytes32 channelId = _block.transaction.header.channelId;
        uint forkCnt = _block.transaction.header.forkCnt;
        uint transactionCnt = _block.transaction.header.transactionCnt;

        //Could do aditional checks here like forkCnt < globalForkCnt, but not needed since it can be detected on-client and disputed
        //Aslo could check if block producer part of state channel, but this too can be discarded on client - interacting on-chain has fees so no reason for someone to spam this
        //TODO? should potentially remove all checks and just have posting blocks? For honest participants it would be cheaper, and spaming would be disacrded regardless at a cost

        ForkDataAvailability storage forkDataAvailability = postedBlockCalldata[
            channelId
        ][forkCnt];

        forkDataAvailability.map[transactionCnt][msg.sender] = BlockCalldata({
            signedBlock: signedBlock,
            timestamp: block.timestamp
        });
        forkDataAvailability.keys.push(
            ForkDataAvailabilityKey(transactionCnt, msg.sender)
        );

        emit BlockCalldataPosted(channelId, signedBlock, block.timestamp);
    }

    function _delegatecall(
        address target,
        bytes memory data
    ) internal returns (bytes memory) {
        (bool success, bytes memory result) = target.delegatecall(data);
        if (!success) {
            if (result.length == 0)
                revert("AStateChannelManagerProxy - Delegatecall failed");
            assembly {
                let returndata_size := mload(result)
                revert(add(32, result), returndata_size)
            }
        }
        return result;
    }

    function getDispute(
        bytes32 channelId
    ) public view override returns (Dispute memory) {
        return disputes[channelId];
    }

    //TODO! - temporary
    function createDispute(
        bytes32 channelId,
        uint forkCnt,
        bytes memory encodedLatestFinalizedState,
        bytes memory encodedLatestCorrectState,
        ConfirmedBlock[] memory virtualVotingBlocks,
        address timedoutParticipant,
        uint foldedTransactionCnt,
        Proof[] memory proofs
    ) public override {
        _delegatecall(
            address(disputeManagerFacet),
            abi.encodeCall(
                disputeManagerFacet.createDispute,
                (
                    channelId,
                    forkCnt,
                    encodedLatestFinalizedState,
                    encodedLatestCorrectState,
                    virtualVotingBlocks,
                    timedoutParticipant,
                    foldedTransactionCnt,
                    proofs
                )
            )
        );
    }

    function challengeDispute(
        bytes32 channelId,
        uint forkCnt,
        uint challengeCnt,
        Proof[] memory proofs,
        ConfirmedBlock[] memory virtualVotingBlocks,
        bytes memory encodedLatestFinalizedState,
        bytes memory encodedLatestCorrectState
    ) public override {
        _delegatecall(
            address(disputeManagerFacet),
            abi.encodeCall(
                disputeManagerFacet.challengeDispute,
                (
                    channelId,
                    forkCnt,
                    challengeCnt,
                    proofs,
                    virtualVotingBlocks,
                    encodedLatestFinalizedState,
                    encodedLatestCorrectState
                )
            )
        );
    }

    function getForkCnt(
        bytes32 channelId
    )
        public
        view
        override(StateChannelCommon, StateChannelManagerInterface)
        returns (uint)
    {
        return StateChannelCommon.getForkCnt(channelId);
    }

    function getParticipants(
        bytes32 channelId,
        uint forkCnt
    )
        public
        override(StateChannelCommon, StateChannelManagerInterface)
        returns (address[] memory)
    {
        return StateChannelCommon.getParticipants(channelId, forkCnt);
    }

    function getNextToWrite(
        bytes32 channelId,
        bytes memory encodedState
    )
        public
        override(StateChannelCommon, StateChannelManagerInterface)
        returns (address)
    {
        return StateChannelCommon.getNextToWrite(channelId, encodedState);
    }

    function isGenesisState(
        bytes32 channelId,
        uint forkCnt,
        bytes memory encodedFinalizedState
    )
        public
        view
        override(StateChannelCommon, StateChannelManagerInterface)
        returns (bool)
    {
        return
            StateChannelCommon.isGenesisState(
                channelId,
                forkCnt,
                encodedFinalizedState
            );
    }

    function getP2pTime()
        public
        view
        override(StateChannelCommon, StateChannelManagerInterface)
        returns (uint)
    {
        return StateChannelCommon.getP2pTime();
    }

    function getAgreementTime()
        public
        view
        override(StateChannelCommon, StateChannelManagerInterface)
        returns (uint)
    {
        return StateChannelCommon.getAgreementTime();
    }

    function getChainFallbackTime()
        public
        view
        override(StateChannelCommon, StateChannelManagerInterface)
        returns (uint)
    {
        return StateChannelCommon.getChainFallbackTime();
    }

    function getChallengeTime()
        public
        view
        override(StateChannelCommon, StateChannelManagerInterface)
        returns (uint)
    {
        return StateChannelCommon.getChallengeTime();
    }

    function getAllTimes()
        public
        view
        override(StateChannelCommon, StateChannelManagerInterface)
        returns (uint, uint, uint, uint)
    {
        return StateChannelCommon.getAllTimes();
    }

    function getBlockCallData(
        bytes32 channelId,
        uint forkCnt,
        uint transactionCnt,
        address participant
    )
        public
        view
        override(StateChannelCommon, StateChannelManagerInterface)
        returns (bool found, BlockCalldata memory)
    {
        return
            StateChannelCommon.getBlockCallData(
                channelId,
                forkCnt,
                transactionCnt,
                participant
            );
    }

    function getChainLatestBlockTimestamp(
        bytes32 channelId,
        uint forkCnt,
        uint maxTransactionCnt
    )
        public
        view
        override(StateChannelCommon, StateChannelManagerInterface)
        returns (uint)
    {
        return
            StateChannelCommon.getChainLatestBlockTimestamp(
                channelId,
                forkCnt,
                maxTransactionCnt
            );
    }

    function getGenesisTimestamp(
        bytes32 channelId,
        uint forkCnt
    )
        public
        view
        override(StateChannelCommon, StateChannelManagerInterface)
        returns (uint)
    {
        return StateChannelCommon.getGenesisTimestamp(channelId, forkCnt);
    }

    function isChannelOpen(
        bytes32 channelId
    )
        public
        view
        override(StateChannelCommon, StateChannelManagerInterface)
        returns (bool)
    {
        return StateChannelCommon.isChannelOpen(channelId);
    }
}
