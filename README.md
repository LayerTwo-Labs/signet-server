# Run Your Own Play-Money Server

## Docker

The instructions below are for running native binaries. If you instead prefer
running things through Docker, take a look at 
[`docker-compose.yml`](./docker-compose.yml). In there you'll find configuration
for L1 Bitcoin Core, the BIP300/301 enforcer, several sidechains, Electrum, a 
L2 fast withdrawal server and L1 faucet. 

A couple of important notes, if you want to run this in Docker: 

1. The signet setup described in section 2 and 3 still needs to be 
   performed, in such a way that the signet mining key exists within
   the Bitcoin Core L1 wallet
2. In order to receive the freshly mined signet coins you need to 
   update the `--signet-miner-coinbase-recipient` parameter to 
   the BIP300/301 enforcer to an address belonging to your Bitcoin Core
   L1 wallet. 

Note that some of the values in the 
configuration file might need slight changes, 

## Native binaries

### 1. Basics

* Spin up a new server (such as Linode), with Ubuntu 24 (or whatever you prefer).

* To it, add:
* * [Bitcoin Core (patched)](https://releases.drivechain.info/L1-bitcoin-patched-latest-x86_64-unknown-linux-gnu.zip)
* * [The BIP 300/301 Enforcer](https://releases.drivechain.info/bip300301-enforcer-latest-x86_64-unknown-linux-gnu.zip)

Create `bitcoin.conf` (at `$HOME/.bitcoin/bitcoin.conf`) , and make sure it contains:

    rpcuser=user
    rpcpassword=password
    txindex=1
    server=1
    zmqpubsequence=tcp://0.0.0.0:29000
      # required to interact with the enforcer   
    signet=1
    signetblocktime=60
      # 1 minute block times. Note that /everyone/ who connects to this signet
      # must have this exact configuration value.

Step 2 (below) will add the `signetchallenge=...` line. 

### 2. Create a Mining Key

This key will sign a new block into existence, every 60 seconds.

Note: This is using Fish shell, if you are using Bash or Zsh then ask an AI for help.

    $ mkdir custom-signet
    $ ./build/src/bitcoind -daemon -regtest -datadir=$PWD/custom-signet

    $ ./build/src/bitcoin-cli -regtest -datadir=$PWD/custom-signet \
         createwallet custom-signet

    $ set signet_challenge (./build/src/bitcoin-cli -regtest -datadir=$PWD/custom-signet \
                         getaddressinfo $address | jq -r .scriptPubKey)
    
    # Add the output of this command to your bitcoin.conf file!
    $ echo signetchallenge=$signet_challenge 

    # Need the wallet descriptors to be able to import the wallet into
    $ set descriptors (./build/src/bitcoin-cli -regtest -datadir=$PWD/custom-signet \
                         listdescriptors true | jq -r .descriptors)

    # We're finished with the regtest wallet!
    $ ./build/src/bitcoin-cli -regtest -datadir=$PWD/custom-signet stop


### 3. Create the signet wallet


    $ ./build/src/bitcoind -daemon -signet -datadir=$PWD/custom-signet

    $ ./build/src/bitcoin-cli -signet -datadir=$PWD/custom-signet \
         createwallet custom-signet

    $ ./build/src/bitcoin-cli -signet -datadir=$PWD/custom-signet \
        importdescriptors "$descriptors"
    
    # Save an address from the wallet. This will be used for mining
    # purposes, later. 
    $ set address (./build/src/bitcoin-cli -signet -datadir=$PWD/custom-signet getnewaddress)


### 4. Start the enforcer

    $ set mining_address (./build/src/bitcoin-cli -signet getnewaddress)
    $ ./bip300301_enforcer \
        --node-rpc-addr=localhost:38332 \
        --node-rpc-user=user \
        --node-rpc-pass=password \
        --node-zmq-addr-sequence=tcp://0.0.0.0:29000 \
        --enable-wallet \
        --wallet-auto-create \
        --signet-miner-coinbase-recipient=$address

### 5. Start mining

Mining blocks happen through a gRPC endpoint on the BIP300/301 enforcer wallet. 
This is so we're able to construct the necessary BIP300 coinbase messages. 

Calling the endpoint can be done with the [Buf CLI](https://buf.build/docs/cli/installation/). 

    $ buf curl --protocol grpc \
        --http2-prior-knowledge \
        http://localhost:50051/cusf.mainchain.v1.WalletService/GenerateBlocks

If you want to continuously generate blocks you could run this command
in a loop with 1 minute wait times in between, or configure a Cron job. 

Congrats, you now have your own play money server!

### 6. Give This Info To Your Friends

Those joining the network (ie, non-mining nodes) must have the same bitcoin.conf , plus an "addnode" line.

The `addnode` line is your server's IP address + port 8332. The L2L hosted signet server runs on `172.105.148.135:8332`.

    rpcuser=user
    rpcpassword=password
    server=1
    txindex=1
    signet=1
    signetblocktime=60
    signetchallenge=00141f61d57873d70d28bd28b3c9f9d6bf818b5a0d6a
    zmqpubsequence=tcp://0.0.0.0:29000
    addnode=172.105.148.135:8332

But yours will have different values for `addnode` and `signetchallenge`.
