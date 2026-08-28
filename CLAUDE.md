# Notes for agents working in this sandbox

- **Do not run a project's production build here.** Builds that start a runtime
  and then talk to it over a socket, such as `astro build` on the Cloudflare
  adapter, cannot connect: the build fails and leaves the `workerd` it spawned
  running at full CPU. Several of those will wedge the box. Type-checking
  (`pnpm check`) and a dev server are what work, and for a repo that deploys on
  push, the remote build is the gate anyway.
