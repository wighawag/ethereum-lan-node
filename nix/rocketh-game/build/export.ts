/**
 * Export the `lan` deployment records (written by ./deploy.ts) to the game's
 * web app, as `rocketh-export -e lan --ts <LAN_EXPORT_TS>` would, but with
 * the box's chain DESCRIBED: it is in no public chain list, and the game's
 * rocketh config need not name it, so the export would otherwise label it
 * "unknown" with an "UNKNOWN" currency. Run by ../default.nix from the game's
 * contracts/scripts/lan-build/.
 */
import {readAndResolveConfig} from '@rocketh/node';
import {run} from '@rocketh/export';
const CHAIN_ID = Number(process.env.LAN_CHAIN_ID ?? 19216801);
const config = await readAndResolveConfig({});
const chains = {...(config as any).chains};
chains[CHAIN_ID] = {
	...chains[CHAIN_ID],
	info: {
		id: CHAIN_ID,
		name: 'LAN',
		nativeCurrency: {name: 'Ether', symbol: 'ETH', decimals: 18},
		rpcUrls: {default: {http: ['http://ethereum.local:8545']}},
		testnet: true,
	},
};
await run({...config, chains} as typeof config, 'lan', {tots: [process.env.LAN_EXPORT_TS!]});
