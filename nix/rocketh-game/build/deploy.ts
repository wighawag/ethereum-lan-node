/**
 * Deploy a template-tree game's contracts for this box WITHOUT the box: into a chain that exists only for this process, with the
 * box's chain id, so that the web app can be built with the addresses the box
 * will have. Run by ../default.nix at build time, where there is no network,
 * from the game's contracts/scripts/lan-build/ (it is copied there, so that
 * `hardhat`, `@rocketh/*` and the game's rocketh/ resolve as the game's own).
 *
 * It writes the `lan` deployment records (exported to the web app) and
 * `LAN_TRANSACTIONS` (default deployments/lan.transactions.json): every
 * transaction the deploy sent, which the box's deploy step replays
 * (../deploy.sh) against its real chain. That file sits BESIDE the
 * records, not among them, because rocketh reads every file in
 * deployments/lan/ as a deployment.
 *
 * WHY THE ADDRESSES ARE THE BOX'S. Every contract is deployed through the
 * deterministic-deployment proxy at 0x4e59b448..., which the box's genesis
 * predeploys and which rocketh deploys here with the same pre-signed
 * transaction, so an address depends only on the salt and the init code: not
 * on the chain, its history, or a nonce. A setup call is kept only if its
 * `execute` has a guard, which the box reads before replaying it
 * (./record.ts); anything else is refused (./replayable.ts says why). Every sender is one of the first 20 accounts of the test
 * mnemonic, on the box as here.
 *
 * THE BOX'S GENESIS HASH (`LAN_GENESIS_HASH`, from ../default.nix) replaces
 * this chain's in the records, so the exported deployments name the box's
 * chain: the app keys what it stores by it, and an indexer refuses a node
 * whose block 0 is not the one the records name. It is written into the
 * transactions file too, where ../deploy.sh checks it against the box's
 * block 0.
 *
 * INSTANT MINING AND AN AUTOMATIC GAS PRICE are forced, since the `default`
 * network differs across the template tree.
 *
 * To run it by hand in a game's repo, copy this directory to
 * contracts/scripts/lan-build/ and run `LAN_CHAIN_ID=19216801 pnpm exec hardhat
 * run --build-profile production scripts/lan-build/deploy.ts` from contracts/.
 * It leaves deployments/lan/ behind (gitignored there, and skipped by the
 * game's scripts/ensure-deployments.mjs).
 */
import {network} from 'hardhat';
import {existsSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {dirname, resolve} from 'node:path';
import {FACTORY, replayableTransactions} from './replayable.js';
import {recordingEnvironment, type Recorded} from './record.js';
import {MNEMONIC_ACCOUNTS} from './accounts.js';

/** The box's chain id (nix/genesis.json; ../default.nix passes it). */
const CHAIN_ID = Number(process.env.LAN_CHAIN_ID ?? 19216801);
const out = resolve(
	process.env.LAN_TRANSACTIONS ?? 'deployments/lan.transactions.json',
);
/** The box's block 0 (../default.nix), or this chain's own when unset. */
const GENESIS_HASH = process.env.LAN_GENESIS_HASH;

const connection = await network.connect({
	network: 'default',
	override: {
		chainId: CHAIN_ID,
		mining: {auto: true, interval: 0},
		gasPrice: 'auto',
	},
});
const provider = connection.provider;

const recorded: Recorded = new Map();
const env = await recordingEnvironment(recorded)({
	provider,
	environment: 'lan',
	saveDeployments: true,
});

let transactions;
try {
	transactions = await replayableTransactions(
		provider,
		MNEMONIC_ACCOUNTS,
		env.deployments,
		recorded,
	);
} catch (error) {
	throw new Error(`lan-build: ${(error as Error).message}`);
}
if (GENESIS_HASH) {
	// rocketh keeps the chain's identity beside the records it saved.
	const chainFile = resolve('deployments/lan/.chain');
	if (!existsSync(chainFile))
		throw new Error(`lan-build: no ${chainFile} to give the box's genesis hash`);
	const chain = JSON.parse(readFileSync(chainFile, 'utf8'));
	writeFileSync(chainFile, JSON.stringify({...chain, genesisHash: GENESIS_HASH}));
}
mkdirSync(dirname(out), {recursive: true});
writeFileSync(
	out,
	JSON.stringify(
		{
			chainId: CHAIN_ID,
			...(GENESIS_HASH ? {genesisHash: GENESIS_HASH} : {}),
			factory: FACTORY,
			transactions,
		},
		null,
		'\t',
	) + '\n',
);
console.log(
	`lan-build: ${transactions.length} transactions for chain ${CHAIN_ID} in ${out}`,
);
for (const [name, d] of Object.entries(env.deployments))
	console.log(`  ${name} ${d.address}`);
