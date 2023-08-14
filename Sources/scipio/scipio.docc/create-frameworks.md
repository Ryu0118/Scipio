# Convert single Swift Package to XCFramework

Use `create` mode to generate XCFramework from any Swift Package

## Overview

XCFrameworks can be generated from any Swift Package with the create command.

This command is useful when generating XCFrameworks from an existing Swift Package.

Unlike the `prepare` command, there is no need to prepare a new package manifest.

## Usage

Let's see an example to generate XCFrameworks from [apple/swift-log](https://github.com/apple/swift-log)

At the first, clone the package to your local machine

```bash
$ git clone https://github.com:apple/swift-log.git 
```

Then, run the create command with the path to the package.

```bash
$ swift create path/to/swift-log
🔁 Resolving Dependencies...
📦 Building Logging for iOS, iPhone Simulator
🚀 Combining into XCFramework...
❇️ Succeeded.
```

It's all to do to convert a Swift Package into XCFrameworks.

### Options

Basically, this command can take the same options as the `prepare` command. See <doc:prepare-cache-for-applications#Options>

#### Specify target platforms

In the create command, you can create an XCFramework that contains only arbitrary platforms with the `-platforms` option.

```bash
$ swift create --platforms iOS --platforms watchOS path/to/swift-log
```

This command make a XCFramework combined only iOS and watchOS.

This is because, unlike the prepare command, the existing Swift Package lists all supported platforms.
By default, it builds for all of them.

