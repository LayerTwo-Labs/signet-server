# Run Your Own Play-Money Server

### 1. Basics

* Spin up a new server (such as linode), with Ubuntu 24 (or whatever you prefer).

* To it, add:
* * [Bitcoin Core (patched)](https://releases.drivechain.info/L1-bitcoin-patched-latest-x86_64-unknown-linux-gnu.zip)
* * [The Bip300 Enforcer](https://releases.drivechain.info/bip300301-enforcer-latest-x86_64-unknown-linux-gnu.zip)

Create bitcoin.conf (at /.bitcoin/bitcoin.conf) , and make sure it contains:

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

Step 2 (below) will add the signetchallenge=... line. 

### 2. Create a Mining Key

This key will sign a new block into existence, every 60 seconds.

Note: This is using Fish shell, if you are using Bash or Zsh then ask an AI for help.

    $ mkdir l2l-signet
    $ ./build/src/bitcoind -daemon -regtest -datadir=$PWD/l2l-signet

    $ ./build/src/bitcoin-cli -regtest -datadir=$PWD/l2l-signet \
         createwallet l2l-signet

    $ set signet_challenge (./build/src/bitcoin-cli -regtest -datadir=$PWD/l2l-signet \
                         getaddressinfo $address | jq -r .scriptPubKey)

    $ echo signetchallenge=$signet_challenge >> l2l-signet/bitcoin.conf

    # Need the wallet descriptors to be able to import the wallet into
    $ set descriptors (./build/src/bitcoin-cli -regtest -datadir=$PWD/l2l-signet \
                         listdescriptors true | jq -r .descriptors)

    # We're finished with the regtest wallet!
    $ ./build/src/bitcoin-cli -regtest -datadir=$PWD/l2l-signet stop


### 3. Create the signet wallet


    $ ./build/src/bitcoind -daemon -signet -datadir=$PWD/l2l-signet

    $ ./build/src/bitcoin-cli -signet -datadir=$PWD/l2l-signet \
         createwallet l2l-signet

    $ ./build/src/bitcoin-cli -signet -datadir=$PWD/l2l-signet \
        importdescriptors "$descriptors"


### 4. Start mining

This will run the 'generate' command, creating a new block on your network every 60 seconds. 


    $ set address (./build/src/bitcoin-cli -signet -datadir=$PWD/l2l-signet getnewaddress)

    $ ./contrib/signet/miner \
        --cli "bitcoin-cli -signet -datadir=$PWD/l2l-signet" \
        generate --address $address \
        --grind-cmd "$PWD/build/src/bitcoin-util grind" \
        --min-nbits --ongoing --block-interval 60


You now have your own play money server.

### 5. Give This Info To Your Friends

Those joining the network (ie, non-mining nodes) must have the same bitcoin.conf , plus an "addnode" line.

The addnode line is your server's IP address + port 8332 . For us at L2L, this is 172.105.148.135:8332 :

    rpcuser=user
    rpcpassword=password
    server=1
    txindex=1
    signet=1
    signetblocktime=60
    signetchallenge=00141f61d57873d70d28bd28b3c9f9d6bf818b5a0d6a
    zmqpubsequence=tcp://0.0.0.0:29000
    addnode=172.105.148.135:8332

But yours will have different values for "addnode", "signetchallenge".

### 6. Activate a Sidechain

The file mine_signet.sh will attempt to activate the thunder sidechain in slot 1, and mine a few blocks. 

### 7. Checking in on the Mining Server

If the mining server crashes (or stops for any reason), you can examine it by:

* ssh into server
* su [your user name]
* cd into /home/[your user name]
* run ps aux | grep mine_signet to determine if the mining script is running

Then you can restart it by re-running the commands in Step 4.
