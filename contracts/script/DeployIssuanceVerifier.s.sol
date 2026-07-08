// contracts/script/DeployIssuanceVerifier.s.sol
import {Script, console} from "forge-std/Script.sol";
import {
    IssuanceHonkVerifier
} from "../src/phase3/verifier/IssuanceVerifier.sol";
contract DeployIssuanceVerifier is Script {
    function run() external {
        vm.startBroadcast();
        IssuanceHonkVerifier v = new IssuanceHonkVerifier();
        vm.stopBroadcast();
        console.log("IssuanceVerifier:", address(v));
    }
}
