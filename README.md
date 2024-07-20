# Initial Ideas

## NetworthDb

An App with the goal for converting bank statements, credit card statements and investment information into an
editable format like JSON or SQL database.

Requires the following work to be done.

## Fetching

- Emails
- Filesystem (Reading files)
- Bank's API?
- Account Aggregator?

## Parsing files

- Decrypt & parse PDFs
- Decrypt & parse XLSX

## Output

- JSON
- Add to Database

- The app must allow easily adding new fetching sources
- The app must allow adding a new bank's input in the from a single file without getting too much into the code.
- The app must allow the user to be able to select their output format.

## Meta

- Create repo graph
- EditorConfig
- SemVer
- README.md: should contain Goal & Setup

TODO:

- [ ] Create a database schema

Discuss:

- We keep NetworthDb & other core product open-source but consider monetisation of the product in the future. "NetworthCloud"
- I should be able to mark transaction's "category" and "sub-category"
  - I should auto mark all transactions based on "receiver's address" and/or "date" and/or "amount" and/or "source address" etc
- I should be able to share a "cleaned" version of my financial transactions with my CA
- E2E encrypt more than just the password; how about user information is encrypted and decrypted and put in jwt, then used in a decrypted state from the jwt during session!?
  - and some transaction information is also encrypted and stored in Db, then decrypted at the time of action -- how about some of these features are optional
- Support for multiple currencies (i.e what if I have an account in dollars)

## NetworthHttp

An App with the goal of using NetworthDb as a library and providing a _GraphQL_ backend to allow implementation
of a client application.

## Client application(s)

- We can use [lightdash](https://www.lightdash.com/)
- MoneyMap?
