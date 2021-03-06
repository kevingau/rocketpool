pragma solidity 0.5.8;

// Contracts
import "./RocketBase.sol";
// Interfaces
import "./interface/RocketNodeInterface.sol";
import "./interface/minipool/RocketMinipoolInterface.sol";
import "./interface/minipool/RocketMinipoolFactoryInterface.sol";
import "./interface/settings/RocketMinipoolSettingsInterface.sol";
import "./interface/utils/lists/AddressSetStorageInterface.sol";
import "./interface/utils/pubsub/PublisherInterface.sol";
// Libraries
import "./lib/SafeMath.sol";



/// @title First alpha of an Ethereum POS pool - Rocket Pool! - This is main pool management contract
/// @author David Rugendyke
contract RocketPool is RocketBase {

    /*** Libs  ******************/

    using SafeMath for uint;

    /*** Contracts **************/

    RocketNodeInterface rocketNode = RocketNodeInterface(0);                                                // Interface for node methods
    RocketMinipoolInterface rocketMinipool = RocketMinipoolInterface(0);                                    // Interface for common minipool methods
    RocketMinipoolFactoryInterface rocketMinipoolFactory = RocketMinipoolFactoryInterface(0);               // Where minipools are made
    RocketMinipoolSettingsInterface rocketMinipoolSettings = RocketMinipoolSettingsInterface(0);            // Settings for the minipools
    AddressSetStorageInterface addressSetStorage = AddressSetStorageInterface(0);                           // Address list utility
    PublisherInterface publisher = PublisherInterface(0);                                                   // Main pubsub system event publisher

  
    /*** Events ****************/

    event PoolCreated (
        address indexed _address,
        bytes32 indexed _durationID,
        uint256 created
    );

    event PoolRemoved (
        address indexed _address,
        uint256 created
    );


    /*** Modifiers *************/

    /// @dev Only registered minipool addresses can access
    /// @param _minipoolAddress pool account address.
    modifier onlyMinipool(address _minipoolAddress) {
        require(rocketStorage.getBool(keccak256(abi.encodePacked("minipool.exists", _minipoolAddress))), "Caller must be a valid minipool");
        _;
    }

       
    /*** Constructor *************/

    /// @dev rocketPool constructor
    constructor(address _rocketStorageAddress) RocketBase(_rocketStorageAddress) public {
        // Version
        version = 1;
    }


    /*** Subscriptions ***********/

    /// @dev Minipool status changed
    function onMinipoolStatusChange(address _minipoolAddress, uint8 _newStatus) public onlyLatestContract("utilPublisher", msg.sender) {

        // Staking / timed out - set minipool unavailable
        if (_newStatus == uint8(2) || _newStatus == uint8(6)) { minipoolAvailable(_minipoolAddress, false); }

        // Withdrawn / timed out - decrease total network ether capacity & assigned ether
        if (_newStatus == uint8(4) || _newStatus == uint8(6)) {
            rocketMinipool = RocketMinipoolInterface(_minipoolAddress);
            networkDecreaseTotalEther("capacity", rocketMinipool.getStakingDurationID(), rocketMinipool.getUserDepositCapacity());
            networkDecreaseTotalEther("assigned", rocketMinipool.getStakingDurationID(), rocketMinipool.getUserDepositTotal());
        }

    }

    /// @dev Minipool user deposit made
    function onMinipoolUserDeposit(string memory _durationID, uint256 _depositAmount) public onlyLatestContract("utilPublisher", msg.sender) {
        networkIncreaseTotalEther("assigned", _durationID, _depositAmount);
    }


    /*** Getters *************/

    /// @dev Check if this minipool exists in the network
    /// @param _miniPoolAddress The address of the minipool to check exists
    function getPoolExists(address _miniPoolAddress) view public returns(bool) {
        return rocketStorage.getBool(keccak256(abi.encodePacked("minipool.exists", _miniPoolAddress)));
    }


    /// @dev Returns a count of the current minipools
    function getPoolsCount() public returns(uint256) {
        addressSetStorage = AddressSetStorageInterface(getContractAddress("utilAddressSetStorage"));
        return addressSetStorage.getCount(keccak256(abi.encodePacked("minipools", "list")));
    }


    /// @dev Return a current minipool by index
    function getPoolAt(uint256 _index) public returns (address) {
        addressSetStorage = AddressSetStorageInterface(getContractAddress("utilAddressSetStorage"));
        return addressSetStorage.getItem(keccak256(abi.encodePacked("minipools", "list")), _index);
    }


    // @dev Returns a count of the available minipools under a node
    function getAvailableNodePoolsCount(address _nodeAddress, bool _trusted, string memory _durationID) public returns(uint256) {
        addressSetStorage = AddressSetStorageInterface(getContractAddress("utilAddressSetStorage"));
        return addressSetStorage.getCount(keccak256(abi.encodePacked("minipools", "list.node.available", _nodeAddress, _trusted, _durationID)));
    }


    /// @dev Get the address of a pseudorandom available node's first minipool
    function getRandomAvailableMinipool(bool _trusted, string memory _durationID, uint256 _seed, uint256 _offset) public returns (address) {
        rocketNode = RocketNodeInterface(getContractAddress("rocketNode"));
        addressSetStorage = AddressSetStorageInterface(getContractAddress("utilAddressSetStorage"));
        address nodeAddress = rocketNode.getRandomAvailableNode(_trusted, _durationID, _seed, _offset);
        return addressSetStorage.getItem(keccak256(abi.encodePacked("minipools", "list.node.available", nodeAddress, _trusted, _durationID)), 0);
    }


    /// @dev Get the total ether value of the network by key
    /// @param _type The type of total ether value to retrieve (e.g. "capacity")
    /// @param _durationID The staking duration
    function getTotalEther(string memory _type, string memory _durationID) public view returns (uint256) {
        return rocketStorage.getUint(keccak256(abi.encodePacked("network.ether.total", _type, _durationID)));
    }


    /// @dev Get the current network utilisation (assigned ether / ether capacity) as a fraction of 1 ether
    /// @param _durationID The staking duration
    function getNetworkUtilisation(string memory _durationID) public view returns (uint256) {
        uint256 etherCapacity = getTotalEther("capacity", _durationID);
        if (etherCapacity == 0) { return 1 ether; }
        uint256 base = 1 ether;
        return base.mul(getTotalEther("assigned", _durationID)).div(etherCapacity);
    }


    /*** Methods - Minipool *************/


    /// @dev Create a minipool
    function minipoolCreate(address _nodeOwner, string memory _durationID, bytes memory _validatorPubkey, bytes memory _validatorSignature, bytes32 _validatorDepositDataRoot, uint256 _etherAmount, uint256 _rplAmount, bool _isTrustedNode) public onlyLatestContract("rocketNodeAPI", msg.sender) returns (address) {
        // Get contracts
        rocketMinipoolFactory = RocketMinipoolFactoryInterface(getContractAddress("rocketMinipoolFactory"));
        rocketMinipoolSettings = RocketMinipoolSettingsInterface(getContractAddress("rocketMinipoolSettings"));
        addressSetStorage = AddressSetStorageInterface(getContractAddress("utilAddressSetStorage"));
        // Create minipool contract
        address minipoolAddress = rocketMinipoolFactory.createRocketMinipool(_nodeOwner, _durationID, _validatorPubkey, _validatorSignature, _validatorDepositDataRoot, _etherAmount, _rplAmount, _isTrustedNode);
        // Ok now set our data to key/value pair storage
        rocketStorage.setBool(keccak256(abi.encodePacked("minipool.exists", minipoolAddress)), true);
        // Update minipool indexes 
        addressSetStorage.addItem(keccak256(abi.encodePacked("minipools", "list")), minipoolAddress); 
        addressSetStorage.addItem(keccak256(abi.encodePacked("minipools", "list.node", _nodeOwner)), minipoolAddress);
        addressSetStorage.addItem(keccak256(abi.encodePacked("minipools", "list.duration", _durationID)), minipoolAddress);
        // Set minipool available
        minipoolAvailable(minipoolAddress, true);
        // Increase total network ether capacity
        networkIncreaseTotalEther("capacity", _durationID, rocketMinipoolSettings.getMinipoolLaunchAmount().sub(_etherAmount));
        // Fire the event
        emit PoolCreated(minipoolAddress, keccak256(abi.encodePacked(_durationID)), now);
        // Return minipool address
        return minipoolAddress;
    }

    
    /// @dev Remove a minipool from storage - can only be called by minipools
    function minipoolRemove() external onlyMinipool(msg.sender) returns (bool) {
        // Can we destroy it?
        if(minipoolRemoveCheck(msg.sender)) {
            // Get contracts
            rocketMinipool = RocketMinipoolInterface(msg.sender);
            rocketMinipoolSettings = RocketMinipoolSettingsInterface(getContractAddress("rocketMinipoolSettings"));
            addressSetStorage = AddressSetStorageInterface(getContractAddress("utilAddressSetStorage"));
            // Remove the existance flag
            rocketStorage.deleteBool(keccak256(abi.encodePacked("minipool.exists", msg.sender)));
            // Update minipool indexes
            addressSetStorage.removeItem(keccak256(abi.encodePacked("minipools", "list")), msg.sender);
            addressSetStorage.removeItem(keccak256(abi.encodePacked("minipools", "list.node", rocketMinipool.getNodeOwner())), msg.sender);
            addressSetStorage.removeItem(keccak256(abi.encodePacked("minipools", "list.duration", rocketMinipool.getStakingDurationID())), msg.sender);
            // Set minipool unavailable
            minipoolAvailable(msg.sender, false);
            // Decrease total network ether capacity if minipool was initialised
            if (rocketMinipool.getStatus() == uint8(0)) { networkDecreaseTotalEther("capacity", rocketMinipool.getStakingDurationID(), rocketMinipool.getUserDepositCapacity()); }
            // Fire the event
            emit PoolRemoved(msg.sender, now);
            // Return minipool address
            return true;
        }
        // Safety
        return false;
    }


    /// @dev Can we destroy this minipool? 
    /// @param _minipool The minipool to check
    function minipoolRemoveCheck(address _minipool) public returns (bool) {
        // Get contracts
        rocketMinipool = RocketMinipoolInterface(_minipool);
        rocketMinipoolSettings = RocketMinipoolSettingsInterface(getContractAddress("rocketMinipoolSettings"));
        // Are minipools allowed to be closed?
        if (rocketMinipoolSettings.getMinipoolClosingEnabled() == false) { return false; }
        // If there are deposits in this minipool, it cannot be closed, only empty ones can
        if (rocketMinipool.getDepositCount() > 0) { return false; }
        // If the node operator's deposit still exists in this minipool, it cannot be closed
        if (rocketMinipool.getNodeDepositExists() == true) { return false; }
        // If it passes all these checks, it can close
        return true;
    }


    /// @dev Set a minipool's available status
    /// @param _minipool The minipool address
    /// @param _available Boolean that indicates the availability of the minipool
    function minipoolAvailable(address _minipool, bool _available) private returns (bool) {
        // Get contracts
        addressSetStorage = AddressSetStorageInterface(getContractAddress("utilAddressSetStorage"));
        publisher = PublisherInterface(getContractAddress("utilPublisher"));
        rocketMinipool = RocketMinipoolInterface(_minipool);
        // Get minipool properties
        address nodeOwner = rocketMinipool.getNodeOwner();
        bool trusted = rocketMinipool.getNodeTrusted();
        string memory durationID = rocketMinipool.getStakingDurationID();
        // Check current minipool available status
        int256 minipoolIndex = addressSetStorage.getIndexOf(keccak256(abi.encodePacked("minipools", "list.node.available", nodeOwner, trusted, durationID)), _minipool);
        if (_available && minipoolIndex != -1 || !_available && minipoolIndex == -1) { return false; }
        // Add minipool to / remove from node's available set
        if (_available) { addressSetStorage.addItem(keccak256(abi.encodePacked("minipools", "list.node.available", nodeOwner, trusted, durationID)), _minipool); }
        else { addressSetStorage.removeItem(keccak256(abi.encodePacked("minipools", "list.node.available", nodeOwner, trusted, durationID)), _minipool); }
        // Publish available status event
        publisher.publish(keccak256("minipool.available.change"), abi.encodeWithSignature("onMinipoolAvailableChange(address,bool,address,bool,string)", _minipool, _available, nodeOwner, trusted, durationID));
        // Success
        return true;
    }


    /*** Methods - Network *************/


    /// @dev Increase the total ether value of the network by key
    /// @param _type The type of total ether value to increase (e.g. "capacity")
    /// @param _value The amount to increase the total ether value by
    /// @param _durationID The staking duration
    function networkIncreaseTotalEther(string memory _type, string memory _durationID, uint256 _value) private {
        rocketStorage.setUint(keccak256(abi.encodePacked("network.ether.total", _type, _durationID)),
            rocketStorage.getUint(keccak256(abi.encodePacked("network.ether.total", _type, _durationID))).add(_value)
        );
    }


    /// @dev Decrease the total ether value of the network by key
    /// @param _type The type of total ether value to decrease (e.g. "capacity")
    /// @param _value The amount to decrease the total ether value by
    /// @param _durationID The staking duration
    function networkDecreaseTotalEther(string memory _type, string memory _durationID, uint256 _value) private {
        rocketStorage.setUint(keccak256(abi.encodePacked("network.ether.total", _type, _durationID)),
            rocketStorage.getUint(keccak256(abi.encodePacked("network.ether.total", _type, _durationID))).sub(_value)
        );
    }



    /*** UTILITIES ***********************************************/
    /*** Note: Methods here require passing dynamic memory types
    /*** which can't currently be sent to a library contract (I'd prefer to keep these in a lib if possible, but its not atm)
    /************************************************************
    /// @dev Returns an memory array of addresses that do not equal 0, can be overloaded to support other types 
    /// @dev This is handy as memory arrays have a fixed size when initialised, this reduces the array to only valid values (so that .length works as you'd like)
    /// @dev This can be made redundant when .push is supported on dynamic memory arrays
    /// @param _addressArray An array of a fixed size of addresses
    function utilArrayFilterValuesOnly(address[] memory _addressArray) private pure returns (address[] memory) {
        // The indexes for the arrays
        uint[] memory indexes = new uint[](2); 
        indexes[0] = 0;
        indexes[1] = 0;
        // Calculate the length of the non empty values
        for (uint32 i = 0; i < _addressArray.length; i++) {
            if (_addressArray[i] != 0) {
                indexes[0]++;
            }
        }
        // Create a new memory array at the length of our valid values we counted
        address[] memory valueArray = new address[](indexes[0]);
        // Now populate the array
        for (i = 0; i < _addressArray.length; i++) {
            if (_addressArray[i] != 0) {
                valueArray[indexes[1]] = _addressArray[i];
                indexes[1]++;
            }
        }
        // Now return our memory array with only non empty values at the correct length
        return valueArray;
    }
    */

}