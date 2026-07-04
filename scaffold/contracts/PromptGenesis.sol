// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PromptGenesis — fully on-chain generative art by HEX_PAYLOAD
/// @notice Collectors mint with a text prompt. The contract calls Ritual's
///         image precompile (0x0818); the TEE executor generates the image,
///         uploads it to content-addressed storage, and the AsyncDelivery
///         system reveals the token via callback. The Phase 2 jobId IS the
///         mint transaction hash, so provenance (who, when, which prompt)
///         and the artwork are bound in a single on-chain object.
contract PromptGenesis {
    // ── Ritual system addresses (chain 1979) ──────────────────────────────
    address constant IMAGE_PRECOMPILE = 0x0000000000000000000000000000000000000818;
    address constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000000000830;
    address constant RITUAL_WALLET = 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948;
    address constant ASYNC_DELIVERY = 0x5A16214fF555848411544b005f7Ac063742f39F6;

    // ── Ritual request tuple types ─────────────────────────────────────────
    /// @dev StorageRef: (platform, path, keyRef). See ritual-dapp-da.
    struct StorageRef {
        string platform;
        string path;
        string keyRef;
    }

    /// @dev ModalInput tuple for multimodal precompiles.
    struct ModalInput {
        uint8 inputType; // 0=TEXT
        bytes data;
        string uri;
        bytes32 contentHash;
        uint32 param1;
        uint32 param2;
        bool encrypted;
    }

    /// @dev OutputConfig tuple for multimodal precompiles.
    struct OutputConfig {
        uint8 outputType; // 1=IMAGE
        uint32 maxParam1; // width
        uint32 maxParam2; // height
        uint32 maxParam3;
        bool encryptOutput;
        uint16 numInferenceSteps;
        uint16 guidanceScaleX100;
        uint32 seed;
        uint8 fps;
        string negativePrompt;
    }

    // ── Collection state ───────────────────────────────────────────────────
    struct Piece {
        string prompt;
        address minter;
        bytes32 jobId; // == mint tx hash; the provenance anchor
        string imageUri;
        bytes32 contentHash;
        uint64 mintedAt;
        bool revealed;
        bool failed;
        string failReason;
    }

    string public name = "HEX_PAYLOAD Genesis";
    string public symbol = "HEXPG";

    address public owner;
    uint256 public nextTokenId = 1;
    uint256 public mintPrice = 0.01 ether;
    uint32 public imageWidth = 1024;
    uint32 public imageHeight = 1024;
    string public model = "black-forest-labs/FLUX.2-klein-4B";

    // Executor config, set by owner (see scripts/configure_executor.py):
    address public executor;
    bytes[] private encryptedSecrets; // ECIES-encrypted storage creds for `executor`
    StorageRef private outputStorageRef;

    mapping(uint256 => Piece) public pieces;
    mapping(bytes32 => uint256) public jobToToken;

    // ── Minimal ERC-721 ────────────────────────────────────────────────────
    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    event MintRequested(uint256 indexed tokenId, bytes32 indexed jobId, address indexed minter, string prompt);
    event Revealed(uint256 indexed tokenId, bytes32 indexed jobId, string imageUri, bytes32 contentHash);
    event RevealFailed(uint256 indexed tokenId, bytes32 indexed jobId, string reason);

    error NotOwner();
    error NotAsyncDelivery();
    error WrongPayment();
    error ExecutorNotConfigured();
    error UnknownJob();
    error NotMinted();
    error NotAuthorized();
    error WrongFrom();
    error ZeroAddress();
    error NotFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // ── Owner configuration ────────────────────────────────────────────────
    /// @notice Point the collection at a TEE executor and its encrypted
    ///         storage credentials (re-encrypt when rotating executors).
    function setExecutorConfig(
        address executor_,
        bytes[] calldata encryptedSecrets_,
        StorageRef calldata storageRef_
    ) external onlyOwner {
        executor = executor_;
        encryptedSecrets = encryptedSecrets_;
        outputStorageRef = storageRef_;
    }

    function setMintPrice(uint256 price) external onlyOwner {
        mintPrice = price;
    }

    function setModel(string calldata model_) external onlyOwner {
        model = model_;
    }

    function setImageSize(uint32 width, uint32 height) external onlyOwner {
        imageWidth = width;
        imageHeight = height;
    }

    /// @notice Fund the contract's RitualWallet balance that pays Phase 2
    ///         execution fees. Lock long (100k blocks) to avoid expiry.
    function depositForFees() external payable {
        (bool ok, ) = RITUAL_WALLET.call{value: msg.value}(
            abi.encodeWithSignature("deposit(uint256)", 100_000)
        );
        require(ok, "RitualWallet deposit failed");
    }

    function withdraw(address payable to) external onlyOwner {
        (bool ok, ) = to.call{value: address(this).balance}("");
        require(ok, "withdraw failed");
    }

    // ── Mint / reveal flow ─────────────────────────────────────────────────
    /// @notice Mint a gestating token and fire the on-chain image generation.
    /// @dev One async tx in flight per EOA (Ritual constraint) — the frontend
    ///      should block a second mint until the previous one reveals.
    ///      Send with an explicit gas limit (~1,000,000); estimation is
    ///      unreliable for async precompile calls.
    function mint(string calldata prompt) external payable returns (uint256 tokenId) {
        if (msg.value != mintPrice) revert WrongPayment();
        if (executor == address(0)) revert ExecutorNotConfigured();

        tokenId = nextTokenId++;
        _mint(msg.sender, tokenId);

        bytes32 jobId = _currentTxHash();
        // One mint per transaction: a second mint in the same tx would share
        // the jobId (== tx hash) and orphan the first token's reveal.
        require(jobToToken[jobId] == 0, "one mint per tx");
        jobToToken[jobId] = tokenId;
        pieces[tokenId] = Piece({
            prompt: prompt,
            minter: msg.sender,
            jobId: jobId,
            imageUri: "",
            contentHash: bytes32(0),
            mintedAt: uint64(block.timestamp),
            revealed: false,
            failed: false,
            failReason: ""
        });

        _requestImage(prompt);
        emit MintRequested(tokenId, jobId, msg.sender, prompt);
    }

    /// @notice Re-fire generation for a token whose reveal failed.
    ///         Only the token owner; re-uses the stored prompt.
    function retry(uint256 tokenId) external {
        Piece storage p = pieces[tokenId];
        if (_ownerOf[tokenId] != msg.sender) revert NotAuthorized();
        if (!p.failed) revert NotFailed();

        bytes32 jobId = _currentTxHash();
        jobToToken[jobId] = tokenId;
        p.jobId = jobId;
        p.failed = false;
        p.failReason = "";

        _requestImage(p.prompt);
        emit MintRequested(tokenId, jobId, msg.sender, p.prompt);
    }

    /// @notice Phase 2 callback — only the AsyncDelivery system may call.
    ///         jobId is the ORIGINAL mint tx hash.
    function onImageReady(bytes32 jobId, bytes calldata responseData) external {
        if (msg.sender != ASYNC_DELIVERY) revert NotAsyncDelivery();
        uint256 tokenId = jobToToken[jobId];
        if (tokenId == 0) revert UnknownJob();

        (
            bool hasError,
            ,
            string memory outputUri,
            bytes32 contentHash,
            ,
            ,
            ,
            ,
            string memory errorMsg
        ) = abi.decode(responseData, (bool, bytes, string, bytes32, bool, uint32, uint32, uint32, string));

        Piece storage p = pieces[tokenId];
        if (hasError) {
            p.failed = true;
            p.failReason = errorMsg;
            emit RevealFailed(tokenId, jobId, errorMsg);
            return;
        }

        p.imageUri = outputUri;
        p.contentHash = contentHash;
        p.revealed = true;
        emit Revealed(tokenId, jobId, outputUri, contentHash);
    }

    // ── Ritual encoding internals ──────────────────────────────────────────
    function _currentTxHash() private view returns (bytes32 h) {
        (bool ok, bytes memory data) = TX_HASH_PRECOMPILE.staticcall("");
        require(ok && data.length >= 32, "tx hash precompile failed");
        h = abi.decode(data, (bytes32));
    }

    /// @dev 18-field multimodal request. Field order per the precompile's
    ///      long-running delivery config: 0 executor, 1 encryptedSecrets,
    ///      2 ttl, 3 secretSignatures, 4 userPublicKey, 5-13 poll/delivery,
    ///      14 model, 15 ModalInput[], 16 OutputConfig, 17 StorageRef.
    function _requestImage(string memory prompt) private {
        ModalInput[] memory inputs = new ModalInput[](1);
        inputs[0] = ModalInput({
            inputType: 0,
            data: bytes(prompt),
            uri: "",
            contentHash: bytes32(0),
            param1: 0,
            param2: 0,
            encrypted: false
        });

        OutputConfig memory output = OutputConfig({
            outputType: 1,
            maxParam1: imageWidth,
            maxParam2: imageHeight,
            maxParam3: 0,
            encryptOutput: false,
            numInferenceSteps: 0,
            guidanceScaleX100: 0,
            seed: 0,
            fps: 0,
            negativePrompt: ""
        });

        bytes memory input = abi.encode(
            executor,
            encryptedSecrets,
            uint256(500), // ttl
            new bytes[](0), // secretSignatures
            bytes(""), // userPublicKey
            uint64(5), // pollIntervalBlocks
            uint64(1000), // maxPollBlock
            "IMAGE_TASK_ID", // taskIdMarker
            address(this), // deliveryTarget
            this.onImageReady.selector, // deliverySelector
            uint256(500_000), // deliveryGasLimit
            uint256(1e9), // deliveryMaxFeePerGas
            uint256(1e8), // deliveryMaxPriorityFeePerGas
            uint256(0), // deliveryValue
            model,
            inputs,
            output,
            outputStorageRef
        );

        (bool ok, ) = IMAGE_PRECOMPILE.call(input);
        require(ok, "image precompile call failed");
    }

    // ── Metadata ───────────────────────────────────────────────────────────
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_ownerOf[tokenId] == address(0)) revert NotMinted();
        Piece storage p = pieces[tokenId];

        string memory status = p.revealed ? "revealed" : (p.failed ? "failed" : "gestating");
        bytes memory json = abi.encodePacked(
            '{"name":"HEX_PAYLOAD Genesis #',
            _toString(tokenId),
            '","description":"Fully on-chain generative art minted through Ritual\'s image precompile. Provenance: the Phase 2 jobId is the mint transaction hash.","image":"',
            p.imageUri,
            '","attributes":[{"trait_type":"Prompt","value":"',
            _escapeJson(p.prompt),
            '"},{"trait_type":"Status","value":"',
            status,
            '"},{"trait_type":"Provenance (jobId = mint tx)","value":"',
            _toHexString(p.jobId),
            '"},{"trait_type":"Content Hash","value":"',
            _toHexString(p.contentHash),
            '"}]}'
        );
        return string(abi.encodePacked("data:application/json;base64,", _base64(json)));
    }

    // ── ERC-721 core ───────────────────────────────────────────────────────
    function balanceOf(address who) external view returns (uint256) {
        if (who == address(0)) revert ZeroAddress();
        return _balanceOf[who];
    }

    function ownerOf(uint256 tokenId) public view returns (address o) {
        o = _ownerOf[tokenId];
        if (o == address(0)) revert NotMinted();
    }

    function approve(address spender, uint256 tokenId) external {
        address o = ownerOf(tokenId);
        if (msg.sender != o && !isApprovedForAll[o][msg.sender]) revert NotAuthorized();
        getApproved[tokenId] = spender;
        emit Approval(o, spender, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        if (to == address(0)) revert ZeroAddress();
        address o = ownerOf(tokenId);
        if (o != from) revert WrongFrom();
        if (msg.sender != o && msg.sender != getApproved[tokenId] && !isApprovedForAll[o][msg.sender]) {
            revert NotAuthorized();
        }
        _balanceOf[from]--;
        _balanceOf[to]++;
        _ownerOf[tokenId] = to;
        delete getApproved[tokenId];
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) ==
                    IERC721Receiver.onERC721Received.selector,
                "unsafe recipient"
            );
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC-165
            interfaceId == 0x80ac58cd || // ERC-721
            interfaceId == 0x5b5e139f; // ERC-721 Metadata
    }

    function _mint(address to, uint256 tokenId) private {
        _balanceOf[to]++;
        _ownerOf[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    // ── String helpers ─────────────────────────────────────────────────────
    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _toHexString(bytes32 value) private pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory buffer = new bytes(66);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            buffer[2 + i * 2] = alphabet[uint8(value[i] >> 4)];
            buffer[3 + i * 2] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(buffer);
    }

    /// @dev Escapes double quotes and backslashes so arbitrary prompts can't
    ///      break out of the JSON string. Control chars are replaced by space.
    function _escapeJson(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 extra;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == '"' || b[i] == "\\") extra++;
        }
        bytes memory out = new bytes(b.length + extra);
        uint256 j;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\") {
                out[j++] = "\\";
                out[j++] = c;
            } else if (uint8(c) < 0x20) {
                out[j++] = " ";
            } else {
                out[j++] = c;
            }
        }
        return string(out);
    }

    function _base64(bytes memory data) private pure returns (string memory) {
        if (data.length == 0) return "";
        string memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        string memory result = new string(4 * ((data.length + 2) / 3));

        assembly {
            let tablePtr := add(table, 1)
            let resultPtr := add(result, 32)
            for {
                let dataPtr := data
                let endPtr := add(data, mload(data))
            } lt(dataPtr, endPtr) {

            } {
                dataPtr := add(dataPtr, 3)
                let input := mload(dataPtr)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(18, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(12, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(6, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(input, 0x3F))))
                resultPtr := add(resultPtr, 1)
            }
            switch mod(mload(data), 3)
            case 1 {
                mstore8(sub(resultPtr, 1), 0x3d)
                mstore8(sub(resultPtr, 2), 0x3d)
            }
            case 2 {
                mstore8(sub(resultPtr, 1), 0x3d)
            }
        }
        return result;
    }
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}
