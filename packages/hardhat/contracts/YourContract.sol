// RentalAgreement.sol
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.15 <0.9.0;

import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import "./RentalCashFlowNFT.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@prb/math/contracts/PRBMathUD60x18.sol";

contract RentalAgreement1 {
    using SafeERC20 for IERC20;
    // Handel the tenancy logic
    address public landlord;
    address public tenant;
    uint256 public rent;
    uint256 public deposit;
    uint256 public rentGuarantee;
    uint256 public nextRentDueTimestamp;
    string public leaseTerm; // Added lease term
    string public houseName;
    string public houseAddress;
    // Handle the token payments
    address public immutable tokenAddress;
    IERC20 public tokenUsedForPayments;
    // Handle the Lending service
    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;
    IPool public immutable POOL;
    // Handle the NFT logic
    RentalCashFlowNFT1 public rentalCashFlowNFT;

    event TenantEnteredAgreement(
        uint256 depositLocked,
        uint256 rentGuaranteeLocked,
        uint256 firstMonthRentPaid
    );
    event EndRental(uint256 returnedToTenant, uint256 returnToLandlord);
    event WithdrawUnpaidRent(uint256 withdrawedFunds);

    modifier onlyTenant() {
        require(msg.sender == tenant, "Restricted to the tenant only");
        _;
    }

    modifier onlyLandlord() {
        require(msg.sender == landlord, "Restricted to the landlord only");
        _;
    }

    constructor(
        address _landlord,
        address _tenantAddress,
        uint256 _rent,
        uint256 _deposit,
        uint256 _rentGuarantee,
        address _tokenUsedToPay,
        string memory _houseName,
        string memory _houseAddress,
        string memory _leaseTerm, // Added lease term in constructor
        address _addressesProvider,
        address _rentalCashFlowNFTaddress
    ) {
        require(
            _tenantAddress != address(0),
            "Tenant cannot be the zero address"
        );
        require(_rent > 0, "rent cannot be 0");

        landlord = _landlord;
        tenant = _tenantAddress;
        rent = _rent;
        deposit = _deposit;
        rentGuarantee = _rentGuarantee;
        houseName = _houseName;
        houseAddress = _houseAddress;
        leaseTerm = _leaseTerm; // Setting lease term
        tokenUsedForPayments = IERC20(_tokenUsedToPay);
        tokenAddress = _tokenUsedToPay;
        ADDRESSES_PROVIDER = IPoolAddressesProvider(_addressesProvider);
        POOL = IPool(ADDRESSES_PROVIDER.getPool());
        rentalCashFlowNFT = RentalCashFlowNFT1(_rentalCashFlowNFTaddress);
    }

    function enterAgreementAsTenant(
        address _landlordAddress,
        uint256 _deposit,
        uint256 _rentGuarantee,
        uint256 _rent
    ) public onlyTenant {
        require(_landlordAddress == landlord, "Incorrect landlord address");
        require(_deposit == deposit, "Incorrect deposit amount");
        require(
            _rentGuarantee == rentGuarantee,
            "Incorrect rent guarantee amount"
        );
        require(_rent == rent, "Incorrect rent amount");

        uint256 deposits = deposit + rentGuarantee;
        tokenUsedForPayments.safeTransferFrom(tenant, address(this), deposits);

        // Lend the deposit
        tokenUsedForPayments.approve(ADDRESSES_PROVIDER.getPool(), deposits);
        POOL.supply(tokenAddress, deposits, address(this), 0);

        tokenUsedForPayments.safeTransferFrom(tenant, landlord, rent);
        nextRentDueTimestamp = block.timestamp + 4 weeks;

        emit TenantEnteredAgreement(deposit, rentGuarantee, rent);
    }

    function payRent() public onlyTenant {
        require(
            tokenUsedForPayments.allowance(tenant, address(this)) >= rent,
            "Not enough allowance"
        );

        address nftOwner = rentalCashFlowNFT.ownerOf(
            uint256(uint160(address(this)))
        );
        if (nftOwner != landlord) {
            tokenUsedForPayments.safeTransferFrom(tenant, nftOwner, rent);
        } else {
            tokenUsedForPayments.safeTransferFrom(tenant, landlord, rent);
        }

        nextRentDueTimestamp += 4 weeks;
    }

    function withdrawUnpaidRent() public onlyLandlord {
        //CAN TODO: let the investor can withdraw unpaid rent if the tenant delays payment
        require(
            block.timestamp > nextRentDueTimestamp,
            "There are no unpaid rent"
        );

        nextRentDueTimestamp += 4 weeks;
        rentGuarantee -= rent;

        //withdarw the rent from supply
        IERC20 aToken = IERC20(0x29598b72eb5CeBd806C5dCD549490FdA35B13cD8);
        uint256 depositedOnLendingService = aToken.balanceOf(address(this));
        aToken.approve(ADDRESSES_PROVIDER.getPool(), depositedOnLendingService);
        POOL.withdraw(tokenAddress, rent, address(this));

        tokenUsedForPayments.safeTransfer(landlord, rent);
    }

    function endRental(uint256 _amountOfDepositBack) public onlyLandlord {
        require(_amountOfDepositBack <= deposit, "Invalid deposit amount");

        // Withdraw all funds from the lending service
        // (uint256 depositedOnLendingService, , , , , ) = POOL.getUserAccountData(address(this));
        IERC20 aToken = IERC20(0x29598b72eb5CeBd806C5dCD549490FdA35B13cD8);
        uint256 depositedOnLendingService = aToken.balanceOf(address(this));
        aToken.approve(ADDRESSES_PROVIDER.getPool(), depositedOnLendingService);
        POOL.withdraw(tokenAddress, depositedOnLendingService, address(this));

        // Calculate total balance and interest earned
        uint256 totalBalance = tokenUsedForPayments.balanceOf(address(this));
        uint256 interestEarned = totalBalance - (deposit + rentGuarantee);

        // Check if there are enough funds in the contract
        require(
            totalBalance >= deposit + rentGuarantee + interestEarned,
            "Insufficient total funds"
        );

        // Return _amountOfDepositBack to the landlord
        if (_amountOfDepositBack > 0) {
            tokenUsedForPayments.safeTransfer(landlord, _amountOfDepositBack);
        }

        // Calculate remaining amount to return to the tenant
        uint256 remainingToTenant = totalBalance - _amountOfDepositBack;

        // Return the remaining deposit, rent guarantee, and interest to the tenant
        require(remainingToTenant > 0, "No funds left for tenant");
        tokenUsedForPayments.safeTransfer(tenant, remainingToTenant);

        // Reset state variables
        deposit = 0;
        rentGuarantee = 0;
        emit EndRental(remainingToTenant, _amountOfDepositBack);
    }

    function getTotalCollateralBase(
        address _userAddress
    ) external view returns (uint256) {
        (uint256 totalCollateralBase, , , , , ) = POOL.getUserAccountData(
            _userAddress
        );
        return totalCollateralBase;
    }

    function mintRentalAgreementAsNFT() public onlyLandlord {
        //Stop Double Minting Logic
        require(
            rentalCashFlowNFT.ownerOf(uint256(uint160(address(this)))) ==
                landlord,
            "NFT already minted for this agreement"
        );
        //Mint Logic
        rentalCashFlowNFT.safeMint(
            landlord,
            tenant,
            address(this),
            rent,
            deposit,
            rentGuarantee,
            leaseTerm,
            houseName,
            houseAddress,
            tokenAddress
        );
    }
}

contract RentalFactory1 {
    mapping(address => RentalAgreement1[]) public rentalsByOwner;

    event NewRentalDeployed(
        address contractAddress,
        address landlord,
        address tenant,
        string houseName,
        string houseAddress
    );

    function createNewRental(
        address _tenantAddress,
        uint256 _rent,
        uint256 _deposit,
        uint256 _rentGuarantee,
        address _tokenUsedToPay,
        string memory _houseName,
        string memory _houseAddress,
        string memory _leaseTerm, // Added lease term in function parameters
        address _addressesProvider,
        address _rentalCashFlowNFTaddress
    ) public {
        RentalAgreement1 newRental = new RentalAgreement1(
            msg.sender,
            _tenantAddress,
            _rent,
            _deposit,
            _rentGuarantee,
            _tokenUsedToPay,
            _houseName,
            _houseAddress,
            _leaseTerm,
            _addressesProvider,
            _rentalCashFlowNFTaddress
        );

        emit NewRentalDeployed(
            address(newRental),
            msg.sender,
            _tenantAddress,
            _houseName,
            _houseAddress
        );
        rentalsByOwner[msg.sender].push(newRental);
    }

    function getRentalsCountByOwner(
        address _owner
    ) public view returns (uint256) {
        return rentalsByOwner[_owner].length;
    }
}

contract RentalCashFlowNFT1 is ERC721 {
    using PRBMathUD60x18 for uint256;
    mapping(uint256 => address) public tokenToRentalAgreement;
    AggregatorV3Interface internal dataFeed;

    struct RentalAgreementDetails {
        address landlord;
        address tenant;
        address rentalAgreementAddress;
        uint256 rent;
        uint256 deposit;
        uint256 rentGuarantee;
        string leaseTerm;
        string houseName;
        string houseAddress;
        address tokenAddress;
        uint256 initialPrice;
    }

    mapping(uint256 => RentalAgreementDetails) public rentalAgreements;

    constructor() ERC721("RentalCashFlowNFT", "RCF") {
        dataFeed = AggregatorV3Interface(
            0x7422A64372f95F172962e2C0f371E0D9531DF276
        );
    }

    function safeMint(
        address landlord,
        address tenant,
        address rentalAgreementAddress,
        uint256 rent,
        uint256 deposit,
        uint256 rentGuarantee,
        string memory leaseTerm,
        string memory houseName,
        string memory houseAddress,
        address tokenAddress
    ) public {
        uint256 tokenId = uint256(uint160(rentalAgreementAddress));
        _safeMint(landlord, tokenId);
        tokenToRentalAgreement[tokenId] = rentalAgreementAddress;
        rentalAgreements[tokenId] = RentalAgreementDetails({
            landlord: landlord,
            tenant: tenant,
            rentalAgreementAddress: rentalAgreementAddress,
            rent: rent,
            deposit: deposit,
            rentGuarantee: rentGuarantee,
            leaseTerm: leaseTerm,
            houseName: houseName,
            houseAddress: houseAddress,
            tokenAddress: tokenAddress,
            initialPrice: calculateInitialPrice(rent)
        });
    }

    function calculateInitialPrice(uint256 Rent) public view returns (uint256) {
        uint256 annualRiskFreeInterestRate = getInterestRate();
        // This function calculates the 12month DCF value of the rent using smart contract
        uint256 presentValue = Rent.mul(
            (1e18 - ((1e18 + annualRiskFreeInterestRate).inv().powu(12e18)))
                .div(annualRiskFreeInterestRate)
        );
        return presentValue;
    }

    function getInterestRate() public view returns (uint256) {
        int256 ETH_APR_90d;
        (
            ,
            /* uint80 roundID */ ETH_APR_90d,
            /*uint startedAt*/
            /*uint timeStamp*/
            /*uint80 answeredInRound*/
            ,
            ,

        ) = dataFeed.latestRoundData();
        uint256 annualRiskFreeInterestRate = uint256(ETH_APR_90d) * (1e11);
        return annualRiskFreeInterestRate;
    }
}