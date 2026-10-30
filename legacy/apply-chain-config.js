const fs = require("fs");
const config = JSON.parse(fs.readFileSync("chain-config.json"), "utf-8");

function replaceEnv(fileSTR, replacement) {
  const [name, ...values] = replacement.split("=");
  if (values.length == 0) {
    throw new Error("expect env assignment");
  }
  const regex = new RegExp(`^${name}=.*$`, "gm");
  if (!regex.test(fileSTR)) {
    return (
      fileSTR +
      `
${replacement}`
    );
  }
  return fileSTR.replaceAll(regex, replacement);
}

function replaceAllInFile(filename, replacements) {
  let content = fs.readFileSync(filename, "utf-8");
  for (const replacement of replacements) {
    content = replaceEnv(content, replacement);
  }
  fs.writeFileSync(filename, content);
}

replaceAllInFile("blockscout/docker-compose/envs/common-frontend.env", [
  `NEXT_PUBLIC_NETWORK_NAME=${config.name}`,
  `NEXT_PUBLIC_NETWORK_SHORT_NAME=${config.shortName || config.name}`,
  `NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID=fa5709ec11b1b1538202bbc2b475ceee`,
  `NEXT_PUBLIC_NETWORK_RPC_URL=http://${config.hostname}:8545`,
  `NEXT_PUBLIC_AD_BANNER_PROVIDER=none`,
  `NEXT_PUBLIC_AD_TEXT_PROVIDER=none`,
]);

replaceAllInFile("blockscout/docker-compose/envs/common-blockscout.env", [
  `SUBNETWORK=${config.name}`,
  `CHAIN_ID=${config.chainId}`,
  `MICROSERVICE_SC_VERIFIER_URL=http://smart-contract-verifier:8050/`,
  `MICROSERVICE_SC_VERIFIER_TYPE=sc_verifier`,
]);

const gethDockerComposeFile = "blockscout/docker-compose/geth.yml";
let gethDockerCompose = fs.readFileSync(gethDockerComposeFile, "utf-8");

const regex = new RegExp(
  `  sc-verifier:
    extends:
      file: \\.\\\/services\\\/smart-contract-verifier\\.yml
      service: smart-contract-verifier
    ports:
      - 8082:8050`,
  "gm"
);

if (!regex.test(gethDockerCompose)) {
  gethDockerCompose =
    gethDockerCompose +
    `
  sc-verifier:
    extends:
      file: ./services/smart-contract-verifier.yml
      service: smart-contract-verifier
    ports:
      - 8082:8050
`;
}
fs.writeFileSync(gethDockerComposeFile, gethDockerCompose);

const proxyDefaultConfTemplateFile =
  "blockscout/docker-compose/proxy/default.conf.template";
let proxyDefaultConfTemplate = fs.readFileSync(
  proxyDefaultConfTemplateFile,
  "utf-8"
);
proxyDefaultConfTemplate = proxyDefaultConfTemplate.replaceAll(
  "localhost",
  config.hostname
);
fs.writeFileSync(proxyDefaultConfTemplateFile, proxyDefaultConfTemplate);

const proxyMicroservicesConfTemplateFile =
  "blockscout/docker-compose/proxy/microservices.conf.template";
let proxyMicroservicesConfTemplate = fs.readFileSync(
  proxyMicroservicesConfTemplateFile,
  "utf-8"
);
proxyMicroservicesConfTemplate = proxyMicroservicesConfTemplate.replaceAll(
  "localhost",
  config.hostname
);
fs.writeFileSync(
  proxyMicroservicesConfTemplateFile,
  proxyMicroservicesConfTemplate
);
