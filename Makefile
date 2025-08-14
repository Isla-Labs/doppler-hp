include .env

export

# Install

install:
	forge install

# Test

test:
	forge test --show-progress

coverage:
	forge coverage --ir-minimum --report lcov

fuzz:
	forge test --mt invariant_ --show-progress

deep-fuzz:
	FOUNDRY_PROFILE=deep forge test --mt invariant_ --show-progress

# Logs

generate-history:
	@bun run ./deployments/cli.ts --output history

# Mainnet protocol deployments

deploy-base:
	@forge script ./script/deploy/DeployBase.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) --verify --etherscan-api-key ${BASESCAN_API_KEY} --broadcast --slow
	$(MAKE) generate-history

deploy-unichain:
	@forge script ./script/deploy/DeployUnichain.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(UNICHAIN_MAINNET_RPC_URL) --verify --etherscan-api-key ${UNISCAN_API_KEY} --broadcast --slow
	$(MAKE) generate-history

# Mainnet V4 deployments

deploy-v4-base:
	@forge script ./script/deploy/DeployV4Base.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) --verify --etherscan-api-key ${BASESCAN_API_KEY} --broadcast --slow
	$(MAKE) generate-history

deploy-v4-unichain:
	@forge script ./script/deployV4/DeployV4Unichain.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(UNICHAIN_MAINNET_RPC_URL) --verify --verifier blockscout --verifier-url $(UNICHAIN_MAINNET_VERIFIER_URL) --broadcast --slow	
	$(MAKE) generate-history

deploy-v4-ink:
	@forge script ./script/deployV4/DeployV4Ink.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(INK_MAINNET_RPC_URL) --broadcast --slow --verify --verifier blockscout --verifier-url $(INK_MAINNET_VERIFIER_URL)
	$(MAKE) generate-history

# Testnet protocol deployments

deploy-base-sepolia:
	@forge script ./script/deploy/DeployBaseSepolia.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) --verify --etherscan-api-key ${BASESCAN_API_KEY} --broadcast --slow
	$(MAKE) generate-history

deploy-unichain-sepolia:
	@forge script ./script/deploy/DeployUnichainSepolia.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(UNICHAIN_SEPOLIA_RPC_URL) --verify --etherscan-api-key ${UNISCAN_API_KEY} --broadcast --slow
	$(MAKE) generate-history

# Staked token factory deployments

deploy-staked-token-factory-base:
	@forge script ./script/DeployStakedTokenFactory.s.sol:DeployStakedTokenFactoryBaseMainnetScript --private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) --verify --etherscan-api-key ${BASESCAN_API_KEY} --broadcast --slow
	$(MAKE) generate-history

deploy-staked-token-factory-base-sepolia:
	@forge script ./script/DeployStakedTokenFactory.s.sol:DeployStakedTokenFactoryBaseSepoliaScript --private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) --verify --etherscan-api-key ${BASESCAN_API_KEY} --broadcast --slow
	$(MAKE) generate-history