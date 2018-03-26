pragma solidity 0.4.18;

import "SafeMath.sol";
import "Math.sol";
import "RLP.sol";
import "Merkle.sol";
import "Validate.sol";
import "PriorityQueue.sol";


/**
 * @title RootChain
 * @dev This contract secures a utxo payments plasma child chain to ethereum
 */


contract RootChain {
    using SafeMath for uint256;
    using RLP for bytes;
    using RLP for RLP.RLPItem;
    using RLP for RLP.Iterator;
    using Merkle for bytes32;

    /*
     * Events
     */
    event Deposit(address depositor, uint256 amount);
    event Exit(address exitor, uint256 utxoPos);

    /*
     *  Storage
     */
    mapping(uint256 => childBlock) public childChain;
    mapping(uint256 => exit) public exits;
    mapping(uint256 => uint256) public exitIds;
    PriorityQueue exitsQueue;
    address public authority;
    /* Block numbering scheme below is needed to prevent Ethereum reorg from invalidating blocks submitted
       by operator. Two mechanisms must be in place to prevent chain from crashing:
       1) don't mine tx that spent fresh deposits; if they are reorged from existence, block is invalid
       2) disappearance of submit block does not affect operator's block numbering; hence tx submitted by
       users that address that block stay valid.
    */
    uint256 public currentChildBlock; /* ends with 000 */
    uint256 public currentDepositBlock; /* takes values in range 1..999 */
    uint256 public recentBlock;
    uint256 public weekOldBlock;
    uint256 public childBlockInterval;
    uint256 public inclusionTimeout;

    struct exit {
        address owner;
        uint256 amount;
        uint256 utxoPos;
    }

    struct childBlock {
        bytes32 root;
        uint256 created_at;
    }

    /*
     *  Modifiers
     */
    modifier isAuthority() {
        require(msg.sender == authority);
        _;
    }

    modifier incrementOldBlocks() {
        while (childChain[weekOldBlock].created_at < block.timestamp.sub(1 weeks)) {
            if (childChain[weekOldBlock].created_at == 0) {
                if (childChain[nextWeekOldChildBlock(weekOldBlock)].created_at == 0)
                    break;
                else {
                    weekOldBlock = nextWeekOldChildBlock(weekOldBlock);
                }
            }
            else weekOldBlock = weekOldBlock.add(1);
        }
        _;
    }

    function nextWeekOldChildBlock(uint256 value)
        public
        view
        returns (uint256)
    {
        return value.div(childBlockInterval).add(1).mul(childBlockInterval);
    }

    function getDepositBlock()
        public
        view
        returns (uint256)
    {
        return currentChildBlock.sub(childBlockInterval).add(currentDepositBlock);
    }

    function RootChain()
        public
    {
        authority = msg.sender;
        childBlockInterval = 1000;
        currentChildBlock = childBlockInterval;
        currentDepositBlock = 1;
        weekOldBlock = 1;
        inclusionTimeout = 2;
        exitsQueue = new PriorityQueue();
    }

    // @dev Allows Plasma chain operator to submit block root
    // @param root The root of a child chain block
    function submitBlock(bytes32 root)
        public
        isAuthority
        incrementOldBlocks
    {
        childChain[currentChildBlock] = childBlock({
            root: root,
            created_at: block.timestamp
        });
        currentChildBlock = currentChildBlock.add(childBlockInterval);
        currentDepositBlock = 1;
    }

    // @dev Allows anyone to deposit funds into the Plasma chain
    // @param txBytes The format of the transaction that'll become the deposit
    // TODO: This needs to be optimized so that the transaction is created
    //       from msg.sender and msg.value
    function deposit(bytes txBytes)
        public
        payable
    {
        require(currentDepositBlock < childBlockInterval);

        var txList = txBytes.toRLPItem().toList(11);
        require(txList.length == 11);

        for (uint256 i; i < 6; i++) {
            require(txList[i].toUint() == 0);
        }
        require(txList[7].toUint() == msg.value);
        require(txList[9].toUint() == 0);

        bytes32 zeroBytes;
        bytes32 root = keccak256(keccak256(txBytes), new bytes(130));
        for (i = 0; i < 16; i++) {
            root = keccak256(root, zeroBytes);
            zeroBytes = keccak256(zeroBytes, zeroBytes);
        }

        childChain[getDepositBlock()] = childBlock({
            root: root,
            created_at: block.timestamp
        });
        currentDepositBlock = currentDepositBlock.add(1);

        Deposit(txList[6].toAddress(), txList[7].toUint());
    }

    function decodeUtxoPos(uint256 utxoPos)
        public
        view
        returns (uint256 blknum, uint256 txindex, uint256 oindex)
    {
        blknum = utxoPos / 1000000000;
        txindex = (utxoPos % 1000000000) / 10000;
        oindex = utxoPos - blknum * 1000000000 - txindex * 10000;
        return (blknum, txindex, oindex);
    }

    function encodeUtxoPos(uint256 blknum, uint256 txindex, uint256 oindex)
        public
        view
        returns (uint256 utxoPos)
    {
        return blknum * 1000000000 + txindex * 10000 + oindex;
    }

    function isDepositBlock(uint256 blknum)
        public
        view
        returns (bool)
    {
        return blknum % 3 > 0;
    }

    function isOldBlock(uint256 blknum)
        public
        view
        returns (bool)
    {
        return (currentChildBlock - blknum) / 1000 > inclusionTimeout;
    }

    function insertExit(uint256 utxoPos, address owner, uint256 amount)
        internal
    {
        uint256 blknum;
        uint256 oindex;
        (blknum, , oindex) = decodeUtxoPos(utxoPos);

        uint256 priority;
        if (blknum < weekOldBlock) {
            priority = (utxoPos / blknum).mul(weekOldBlock);
        } else {
            priority = utxoPos;
        }

        require(exitIds[utxoPos] == 0);
        exitIds[utxoPos] = priority;
        exitsQueue.insert(priority);
        exits[priority] = exit({
            owner: owner,
            amount: amount,
            utxoPos: utxoPos
        });
        Exit(msg.sender, utxoPos);
    }

    function validateOutput(uint256 utxoPos, bytes txBytes, bytes proof, bytes sigs)
        public
        view
    {
        uint256 blknum;
        uint256 txindex;
        uint256 oindex;
        (blknum, txindex, oindex) = decodeUtxoPos(utxoPos);

        validateOutput(blknum, txindex, oindex, txBytes, proof, sigs);
    }

    function validateOutput(uint256 blknum, uint256 txindex, uint256 oindex, bytes txBytes, bytes proof, bytes sigs)
        public
        view
    {
        var txList = txBytes.toRLPItem().toList(11);
        bytes32 root = childChain[blknum].root;

        require(msg.sender == txList[6 + 2 * oindex].toAddress());
        bytes32 txHash = keccak256(txBytes);
        bytes32 merkleHash = keccak256(txHash, ByteUtils.slice(sigs, 0, 130));
        require(Validate.checkSigs(txHash, txList[0].toUint(), txList[3].toUint(), sigs));
        require(merkleHash.checkMembership(txindex, root, proof));
    }

    function validateInputs(uint256 blknum, uint256 oindex, bytes txBytes, bytes inputTxBytes1, bytes inputProof1, bytes inputSigs1, bytes inputTxBytes2, bytes inputProof2, bytes inputSigs2)
        public
        returns (address, uint256)
    {
        var txList = txBytes.toRLPItem().toList(11);

        uint256 inputBlknum1 = txList[0].toUint();
        uint256 inputBlknum2 = txList[3].toUint();

        // If this is an "out of thin air" transaction
        if (inputBlknum1 == 0 && inputBlknum2 == 0) {
            require(isDepositBlock(blknum));
        }

        // Otherwise, check that the inputs are valid
        if (inputBlknum1 > 0) {
            require(isOldBlock(inputBlknum1));
            validateOutput(inputBlknum1, txList[1].toUint(), txList[2].toUint(), inputTxBytes1, inputProof1, inputSigs1);
        }
        if (inputBlknum2 > 0) {
            require(isOldBlock(inputBlknum2));
            validateOutput(inputBlknum2, txList[4].toUint(), txList[5].toUint(), inputTxBytes2, inputProof2, inputSigs2);
        }

        return (txList[6 + 2 * oindex].toAddress(), txList[7 + 2 * oindex].toUint());
    }

    function startExit(uint256 utxoPos, bytes outputTxBytes, bytes outputProof, bytes outputSigs, bytes inputTxBytes1, bytes inputProof1, bytes inputSigs1, bytes inputTxBytes2, bytes inputProof2, bytes inputSigs2)
        public
        incrementOldBlocks
    {
        validateOutput(utxoPos, outputTxBytes, outputProof, outputSigs);

        uint256 blknum;
        uint256 oindex;
        (blknum, , oindex) = decodeUtxoPos(utxoPos);

        address owner;
        uint256 amount;
        (owner, amount) = validateInputs(blknum, oindex, outputTxBytes, inputTxBytes1, inputProof1, inputSigs1, inputTxBytes2, inputProof2, inputSigs2);

        insertExit(utxoPos, owner, amount);
    }

    // @dev Allows anyone to challenge an exiting transaction by submitting proof of a double spend on the child chain
    // @param cUtxoPos The position of the challenging utxo
    // @param eUtxoPos The position of the exiting utxo
    // @param txBytes The challenging transaction in bytes RLP form
    // @param proof Proof of inclusion for the transaction used to challenge
    // @param sigs Signatures for the transaction used to challenge
    // @param confirmationSig The confirmation signature for the transaction used to challenge
    function challengeExit(uint256 cUtxoPos, uint256 eUtxoPos, bytes txBytes, bytes proof, bytes sigs)
        public
    {
        var txList = txBytes.toRLPItem().toList(11);
        require((encodeUtxoPos(txList[0].toUint(), txList[1].toUint(), txList[2].toUint()) == eUtxoPos) || (encodeUtxoPos(txList[3].toUint(), txList[4].toUint(), txList[5].toUint()) == eUtxoPos));

        uint256 txindex = (cUtxoPos % 1000000000) / 10000;
        bytes32 root = childChain[cUtxoPos / 1000000000].root;
        uint256 priority = exitIds[eUtxoPos];
        var txHash = keccak256(txBytes);
        var merkleHash = keccak256(txHash, sigs);
        address owner = exits[priority].owner;

        require(merkleHash.checkMembership(txindex, root, proof));
        delete exits[priority];
        delete exitIds[eUtxoPos];
    }


    // @dev Loops through the priority queue of exits, settling the ones whose challenge
    // @dev challenge period has ended
    function finalizeExits()
        public
        incrementOldBlocks
        returns (uint256)
    {
        uint256 twoWeekOldTimestamp = block.timestamp.sub(2 weeks);
        exit memory currentExit = exits[exitsQueue.getMin()];
        uint256 blknum = currentExit.utxoPos.div(1000000000);
        while (childChain[blknum].created_at < twoWeekOldTimestamp && exitsQueue.currentSize() > 0) {
            currentExit.owner.transfer(currentExit.amount);
            uint256 priority = exitsQueue.delMin();
            delete exits[priority];
            delete exitIds[currentExit.utxoPos];
            currentExit = exits[exitsQueue.getMin()];
        }
    }

    /* 
     *  Constants
     */
    function getChildChain(uint256 blockNumber)
        public
        view
        returns (bytes32, uint256)
    {
        return (childChain[blockNumber].root, childChain[blockNumber].created_at);
    }

    function getExit(uint256 priority)
        public
        view
        returns (address, uint256, uint256)
    {
        exit e = exits[priority];
        return (e.owner, e.amount, e.utxoPos);
    }
}
