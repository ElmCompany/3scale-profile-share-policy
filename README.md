# APICast Profile Sharing Policy
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Description

A custom policy to attach the profile information of calling account as headers to target backends

## Usage

Simply ensure to copy the policy source `src/` within APICast instance and point to it using `APICAST_POLICY_LOAD_PATH` [option](https://github.com/3scale/APIcast/blob/master/doc/parameters.md#apicast_policy_load_path).

Alternatively, use the `openshift.yml` file provided for S2I [deployment as documented offically](https://access.redhat.com/documentation/en-us/red_hat_3scale_api_management/2.9/html/administering_the_api_gateway/apicast_policies#builtin).


## Author

Abdullah Barrak (@abarrak).
