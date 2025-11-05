// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IStateView } from "@v4-periphery/lens/StateView.sol";
import { IPoolManager, IHooks } from "@v4-core/interfaces/IPoolManager.sol";
import { IPositionManager, PositionManager } from "@v4-periphery/PositionManager.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { MineV4MigratorHookParams, mineV4MigratorHook } from "test/shared/AirlockMiner.sol";
import {
    Airlock,
    ModuleState,
    CreateParams,
    ITokenFactory,
    IGovernanceFactory,
    IPoolInitializer,
    ILiquidityMigrator
} from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { StreamableFeesLocker } from "src/StreamableFeesLocker.sol";
import { UniswapV2Migrator, IUniswapV2Router02, IUniswapV2Factory } from "src/UniswapV2Migrator.sol";
import { UniswapV4MigratorHook } from "src/UniswapV4MigratorHook.sol";
import { UniswapV4Migrator } from "src/UniswapV4Migrator.sol";
import { UniswapV3Initializer, IUniswapV3Factory } from "src/UniswapV3Initializer.sol";
import { UniswapV4Initializer, DopplerDeployer } from "src/UniswapV4Initializer.sol";
import { Bundler } from "src/Bundler.sol";
import { DopplerLensQuoter } from "src/lens/DopplerLens.sol";
import { LockableUniswapV3Initializer } from "src/LockableUniswapV3Initializer.sol";
import { NoOpGovernanceFactory } from "src/NoOpGovernanceFactory.sol";
import { NoOpMigrator } from "src/NoOpMigrator.sol";

import { 
    TransparentUpgradeableProxy, 
    ITransparentUpgradeableProxy 
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import { AirlockMultisig } from "src/AirlockMultisig.sol";
import { WhitelistRegistry } from "src/WhitelistRegistry.sol";
import { IWhitelistRegistry } from "src/interfaces/IWhitelistRegistry.sol";
import { FeeRouter } from "src/FeeRouter.sol";
import { MarketSunsetterV0 } from "src/MarketSunsetterV0.sol";
// import { MarketSunsetterOracle } from "src/MarketSunsetterOracle.sol";
// import { MarketSunsetter } from "src/MarketSunsetter.sol";
import { HPLimitRouter } from "src/HPLimitRouterV0.sol";
import { HPSwapRouter } from "src/HPSwapRouter.sol";
import { HPSwapQuoter } from "src/HPSwapQuoter.sol";
import { IV4Quoter } from "src/interfaces/IUtilities.sol";
import { InitGuard } from "src/base/InitGuard.sol";

struct ScriptData {
    uint256 chainId;
    address poolManager;
    address protocolOwner;
    address quoterV2;           // V4Quoter address (naming kept for compatibility)
    address uniswapV2Factory;
    address uniswapV2Router02;
    address uniswapV3Factory;
    address universalRouter;
    address stateView;
    address positionManager;
    address hpController;       // use as controllerMultisig
    address rewardsTreasury;
    address orchestratorProxy;
    bytes32 ethUsdcPoolId;
}

/**
 * @notice Main script that deploys core + periphery with proxy placeholders to break cycles.
 */
abstract contract DeployScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        (
            Airlock airlock,
            TokenFactory tokenFactory,
            UniswapV3Initializer uniswapV3Initializer,
            UniswapV4Initializer uniswapV4Initializer,
            GovernanceFactory governanceFactory,
            UniswapV2Migrator uniswapV2Migrator,
            DopplerDeployer dopplerDeployer,
            StreamableFeesLocker streamableFeesLocker,
            UniswapV4Migrator uniswapV4Migrator,
            UniswapV4MigratorHook migratorHook,
            WhitelistRegistry whitelistRegistry,
            FeeRouter feeRouter,
            TransparentUpgradeableProxy registryProxy,
            TransparentUpgradeableProxy limitRouterProxy,
            TransparentUpgradeableProxy swapRouterProxy,
            TransparentUpgradeableProxy swapQuoterProxy,
            TransparentUpgradeableProxy marketSunsetterProxy
        ) = _deployDoppler(_scriptData);

        Bundler bundler = _deployBundler(_scriptData, airlock);
        DopplerLensQuoter lens = _deployLens(_scriptData);

        vm.stopBroadcast();
    }

    function _deployDoppler(
        ScriptData memory scriptData
    )
        internal
        returns (
            Airlock airlock,
            TokenFactory tokenFactory,
            UniswapV3Initializer uniswapV3Initializer,
            UniswapV4Initializer uniswapV4Initializer,
            GovernanceFactory governanceFactory,
            UniswapV2Migrator uniswapV2LiquidityMigrator,
            DopplerDeployer dopplerDeployer,
            StreamableFeesLocker streamableFeesLocker,
            UniswapV4Migrator uniswapV4Migrator,
            UniswapV4MigratorHook migratorHook,
            WhitelistRegistry whitelistRegistry,
            FeeRouter feeRouter,
            TransparentUpgradeableProxy registryProxy,
            TransparentUpgradeableProxy limitRouterProxy,
            TransparentUpgradeableProxy swapRouterProxy,
            TransparentUpgradeableProxy swapQuoterProxy,
            TransparentUpgradeableProxy marketSunsetterProxy
        )
    {
        require(scriptData.uniswapV2Factory != address(0), "Cannot find UniswapV2Factory address!");
        require(scriptData.uniswapV2Router02 != address(0), "Cannot find UniswapV2Router02 address!");
        require(scriptData.uniswapV3Factory != address(0), "Cannot find UniswapV3Factory address!");
        require(scriptData.positionManager != address(0), "Cannot find PositionManager address!");
        require(scriptData.rewardsTreasury != address(0), "Cannot find rewardsTreasury address!");

        // ---------- Proxy scaffolding (guarded placeholders) ----------
        InitGuard guard = new InitGuard();

        registryProxy     = new TransparentUpgradeableProxy(address(guard), msg.sender, hex"");
        limitRouterProxy  = new TransparentUpgradeableProxy(address(guard), msg.sender, hex"");
        swapRouterProxy   = new TransparentUpgradeableProxy(address(guard), msg.sender, hex"");
        swapQuoterProxy   = new TransparentUpgradeableProxy(address(guard), msg.sender, hex"");

        // Cast proxy addresses to types for convenience (impl will be upgraded later)
        whitelistRegistry = WhitelistRegistry(address(registryProxy));

        // ---------- MarketSunsetter proxy (placeholder impl) ----------

        // TO REPLACE: msOracle + msImpl
        // MarketSunsetterOracle msOracle = new MarketSunsetterOracle();
        // MarketSunsetter msImpl = new MarketSunsetter();

        MarketSunsetterV0 msImpl = new MarketSunsetterV0();
        TransparentUpgradeableProxy marketSunsetterProxy = new TransparentUpgradeableProxy(
            address(msImpl),
            scriptData.orchestratorProxy,
            abi.encodeCall(MarketSunsetterV0.initialize, ())
        );

        // ---------- Airlock (constructor can take feeRouter = 0 now; set later) ----------
        require(scriptData.protocolOwner != address(0), "Protocol owner not set!");
        console.log(unicode"👑 Protocol owner set as %s", scriptData.protocolOwner);

        airlock = new Airlock(
            address(0),                                 // feeRouter (set later)
            address(registryProxy),                     // whitelistRegistry proxy
            address(marketSunsetterProxy),              // marketSunsetter
            scriptData.hpController,                    // controllerMultisig
            msg.sender                                  // owner
        );

        // ---------- FeeRouter (non-upgradeable), then wire into Airlock ----------
        {
            address[] memory recipients = new address[](1);
            recipients[0] = scriptData.rewardsTreasury;
            uint16[] memory bps = new uint16[](1);
            bps[0] = 10_000;

            feeRouter = new FeeRouter(
                recipients,
                bps,
                scriptData.rewardsTreasury,
                scriptData.orchestratorProxy,
                address(registryProxy),
                address(airlock),
                address(swapRouterProxy)
            );

            airlock.setFeeRouter(address(feeRouter));
        }

        // ---------- Core infra ----------
        streamableFeesLocker =
            new StreamableFeesLocker(IPositionManager(scriptData.positionManager), scriptData.protocolOwner);

        uniswapV3Initializer =
            new UniswapV3Initializer(address(airlock), IUniswapV3Factory(scriptData.uniswapV3Factory));
        LockableUniswapV3Initializer lockableUniswapV3Initializer =
            new LockableUniswapV3Initializer(address(airlock), IUniswapV3Factory(scriptData.uniswapV3Factory));

        // Pre-mine hook salt using precomputed migrator address
        address precomputedUniswapV4Migrator = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender));
        (bytes32 salt, address minedMigratorHook) = mineV4MigratorHook(
            MineV4MigratorHookParams({
                hookDeployer: 0x4e59b44847b379578588920cA78FbF26c0B4956C,
                // constructor args used to derive initCodeHash (must match exactly)
                migrator: precomputedUniswapV4Migrator,
                whitelistRegistry: address(registryProxy),
                swapQuoter: address(swapQuoterProxy),
                swapRouter: address(swapRouterProxy),
                limitRouterProxy: address(limitRouterProxy),
                rewardsTreasury: scriptData.rewardsTreasury,
                feeRouter: address(feeRouter)
            })
        );

        // Deploy migrator with pre-mined hook address
        uniswapV4Migrator = new UniswapV4Migrator(
            address(airlock),
            IPoolManager(scriptData.poolManager),
            PositionManager(payable(scriptData.positionManager)),
            streamableFeesLocker,
            IHooks(minedMigratorHook)
        );

        // Deploy hook with deployed migrator address (pass registryProxy)
        migratorHook = new UniswapV4MigratorHook{ salt: salt }(
            uniswapV4Migrator,
            IWhitelistRegistry(address(registryProxy)),
            address(swapQuoterProxy),
            address(swapRouterProxy),
            address(limitRouterProxy),
            scriptData.rewardsTreasury,
            address(feeRouter)
        );

        dopplerDeployer = new DopplerDeployer(IPoolManager(scriptData.poolManager));
        uniswapV4Initializer =
            new UniswapV4Initializer(address(airlock), IPoolManager(scriptData.poolManager), dopplerDeployer);

        // Liquidity Migrator Modules
        uniswapV2LiquidityMigrator = new UniswapV2Migrator(
            address(airlock),
            IUniswapV2Factory(scriptData.uniswapV2Factory),
            IUniswapV2Router02(scriptData.uniswapV2Router02),
            scriptData.protocolOwner
        );
        NoOpMigrator noOpMigrator = new NoOpMigrator(address(airlock));

        // Token/Gov factories
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));
        NoOpGovernanceFactory noOpGovernanceFactory = new NoOpGovernanceFactory();

        // ---------- Airlock Multisig (needed to initialize Registry) ----------
        address[] memory signers = new address[](1);
        signers[0] = msg.sender;
        AirlockMultisig airlockMultisig = new AirlockMultisig(airlock, signers);

        // ---------- Upgrade + initialize proxies (atomic, close init window) ----------

        // WhitelistRegistry
        {
            WhitelistRegistry impl = new WhitelistRegistry();
            bytes memory initData = abi.encodeCall(
                WhitelistRegistry.initialize,
                (address(airlock), address(airlockMultisig), address(marketSunsetterProxy))
            );
            address admin = _proxyAdminOf(address(registryProxy));
            ProxyAdmin(payable(admin)).upgradeAndCall(
                ITransparentUpgradeableProxy(payable(address(registryProxy))),
                address(impl),
                initData
            );
        }

        // HPLimitRouter
        {
            HPLimitRouter limImpl = new HPLimitRouter();
            bytes memory initData = abi.encodeCall(HPLimitRouter.initialize, ());
            address admin = _proxyAdminOf(address(limitRouterProxy));
            ProxyAdmin(payable(admin)).upgradeAndCall(
                ITransparentUpgradeableProxy(payable(address(limitRouterProxy))),
                address(limImpl),
                initData
            );
        }

        // HPSwapRouter
        {
            HPSwapRouter swapImpl = new HPSwapRouter();
            bytes memory initData = abi.encodeCall(
                HPSwapRouter.initialize,
                (
                    IPoolManager(scriptData.poolManager),
                    IWhitelistRegistry(address(registryProxy)),
                    scriptData.orchestratorProxy,
                    address(limitRouterProxy),
                    scriptData.positionManager,
                    scriptData.ethUsdcPoolId
                )
            );
            address admin = _proxyAdminOf(address(swapRouterProxy));
            ProxyAdmin(payable(admin)).upgradeAndCall(
                ITransparentUpgradeableProxy(payable(address(swapRouterProxy))),
                address(swapImpl),
                initData
            );
        }

        // HPSwapQuoter
        {
            HPSwapQuoter quoterImpl = new HPSwapQuoter();
            bytes memory initData = abi.encodeCall(
                HPSwapQuoter.initialize,
                (
                    IPoolManager(scriptData.poolManager),
                    IWhitelistRegistry(address(registryProxy)),
                    IV4Quoter(scriptData.quoterV2),
                    scriptData.orchestratorProxy,
                    scriptData.positionManager,
                    scriptData.ethUsdcPoolId
                )
            );
            address admin = _proxyAdminOf(address(swapQuoterProxy));
            ProxyAdmin(payable(admin)).upgradeAndCall(
                ITransparentUpgradeableProxy(payable(address(swapQuoterProxy))),
                address(quoterImpl),
                initData
            );
        }

        // Verify hook linkage
        require(
            address(uniswapV4Migrator.migratorHook()) == address(migratorHook),
            "Migrator hook is not the expected address"
        );

        // ---------- Whitelist modules ----------
        {
            address[] memory modules = new address[](9);
            modules[0] = address(tokenFactory);
            modules[1] = address(uniswapV3Initializer);
            modules[2] = address(governanceFactory);
            modules[3] = address(uniswapV2LiquidityMigrator);
            modules[4] = address(uniswapV4Initializer);
            modules[5] = address(uniswapV4Migrator);
            modules[6] = address(lockableUniswapV3Initializer);
            modules[7] = address(noOpGovernanceFactory);
            modules[8] = address(noOpMigrator);

            ModuleState[] memory states = new ModuleState[](9);
            states[0] = ModuleState.TokenFactory;
            states[1] = ModuleState.PoolInitializer;
            states[2] = ModuleState.GovernanceFactory;
            states[3] = ModuleState.LiquidityMigrator;
            states[4] = ModuleState.PoolInitializer;
            states[5] = ModuleState.LiquidityMigrator;
            states[6] = ModuleState.PoolInitializer;
            states[7] = ModuleState.GovernanceFactory;
            states[8] = ModuleState.LiquidityMigrator;

            airlock.setModuleState(modules, states);
        }

        // ---------- Handover ----------

        {
            address admin;

            admin = _proxyAdminOf(address(registryProxy));
            ProxyAdmin(payable(admin)).transferOwnership(scriptData.orchestratorProxy);

            admin = _proxyAdminOf(address(limitRouterProxy));
            ProxyAdmin(payable(admin)).transferOwnership(scriptData.orchestratorProxy);

            admin = _proxyAdminOf(address(swapRouterProxy));
            ProxyAdmin(payable(admin)).transferOwnership(scriptData.orchestratorProxy);

            admin = _proxyAdminOf(address(swapQuoterProxy));
            ProxyAdmin(payable(admin)).transferOwnership(scriptData.orchestratorProxy);
        }

        airlock.transferOwnership(address(airlockMultisig));
    }

    function _proxyAdminOf(address proxy) internal view returns (address admin) {
        // EIP-1967 admin slot: bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1)
        bytes32 slot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        admin = address(uint160(uint256(vm.load(proxy, slot))));
    }

    function _deployBundler(ScriptData memory scriptData, Airlock airlock) internal returns (Bundler bundler) {
        require(scriptData.universalRouter != address(0), "Cannot find UniversalRouter address!");
        require(scriptData.quoterV2 != address(0), "Cannot find QuoterV2 address!");
        bundler =
            new Bundler(airlock, UniversalRouter(payable(scriptData.universalRouter)), IQuoterV2(scriptData.quoterV2));
    }

    function _deployLens(
        ScriptData memory scriptData
    ) internal returns (DopplerLensQuoter lens) {
        require(scriptData.poolManager != address(0), "Cannot find PoolManager address!");
        require(scriptData.stateView != address(0), "Cannot find StateView address!");
        lens = new DopplerLensQuoter(IPoolManager(scriptData.poolManager), IStateView(scriptData.stateView));
    }
}