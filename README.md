# CICS Transaction Gateway Testing Environment

Complete testing setup for Apache Camel CICS component using IBM CICS Transaction Gateway 10.1 container.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Container Management](#container-management)
- [Running Integration Tests](#running-integration-tests)
- [Test Structure](#test-structure)
- [Advanced Configuration](#advanced-configuration)
- [Troubleshooting](#troubleshooting)
- [Documentation](#documentation)

## Overview

This project provides:
- **CICS TG 10.1 Container** - IBM CICS Transaction Gateway running in Docker
- **Integration Tests** - Automated tests for Apache Camel CICS component
- **Helper Scripts** - Easy-to-use scripts for container and test management

The CICS TG container image is hosted on Red Hat internal registry and includes everything needed to test Camel CICS integrations.

## Prerequisites

### Required
- **Docker** - For running CICS TG container
- **Access to Red Hat Registry** - `images.paas.redhat.com`

### For Running Integration Tests
- **Java 17** or later
- **Maven 3.8+**
- **Git**
- **IBM CTG Client JAR** - Must be installed to local Maven repository (see below)
- **Access to Red Hat Internal Repositories**:
  - `https://maven.repository.redhat.com/ga`
  - `https://nexus-camel-qe.apps.int.prod-scale-spoke1-aws-us-east-1.itup.redhat.com/repository/ibm-cics-internal`
  - `https://nexus-camel-qe.apps.int.prod-scale-spoke1-aws-us-east-1.itup.redhat.com/repository/fuse-all`

## Quick Start

### 0. Install IBM CTG Client JAR (One-time Setup)

The IBM CTG client library is required for tests but not available in public Maven repositories.

**Automated Installation (Recommended)**

The `run-tests.sh` script will automatically detect if the CTG JAR is missing and install it for you:

```bash
# 1. Start the CICS TG container
./run-cics-container.sh run

# 2. Run the test script - it will auto-install the CTG JAR if needed
./run-tests.sh
```

The script will:
- Check if the CTG client JAR is already installed
- If missing, automatically extract it from the running container
- Install it to your local Maven repository (~/.m2/repository/com/ibm/ctgclient/9.2/)

**Manual Installation (Alternative)**

If you prefer to install manually or have the JAR file from another source:

```bash
# Option 1: Extract from container manually
docker cp cics-ctg-container:/opt/ibm/ctg/lib/ctgclient.jar ./ctgclient-9.2.jar
mvn install:install-file \
  -DgroupId=com.ibm \
  -DartifactId=ctgclient \
  -Dversion=9.2 \
  -Dpackaging=jar \
  -Dfile=./ctgclient-9.2.jar

# Option 2: If you have the JAR from IBM directly
mvn install:install-file \
  -DgroupId=com.ibm \
  -DartifactId=ctgclient \
  -Dversion=9.2 \
  -Dpackaging=jar \
  -Dfile=/path/to/your/ctgclient.jar
```

**Verify installation:**

```bash
ls -la ~/.m2/repository/com/ibm/ctgclient/9.2/ctgclient-9.2.jar
```

### 1. Start CICS TG Container

```bash
# Pull the image
./run-cics-container.sh pull

# Run the container
./run-cics-container.sh run

# Check status
./run-cics-container.sh status
```

The CICS TG server will be running on:
- **Port 2006** - CTG gateway daemon (main port)
- **Port 2035** - CTG SSL port

**Viewing Connection Logs:**

Connection logging is now enabled by default. To see client connections:

```bash
# View real-time logs
./run-cics-container.sh logs

# Or use docker directly
docker logs -f cics-ctg-container
```

You'll see messages like:
```
CTG6506I Client connected: [ConnectionManager-0] - tcp@Socket[addr=/172.17.0.1,port=57938,localport=2006]
CTG6507I Client disconnected: [ConnectionManager-0] - tcp@Socket[addr=/172.17.0.1,port=57938,localport=2006]
```

**Configuration:** The CTG container uses a custom configuration file (`config/ctg.ini`) with:
- `ConnectionLogging = on` - Logs client connections and disconnections
- `CicsLogging = on` - Logs messages from CICS servers

### 2. Run Integration Tests

```bash
# Run tests with default branch (camel-4.14.2-branch)
./run-tests.sh

# Or specify a different branch
./run-tests.sh camel-4.14.2-branch

# Or run specific test
./run-tests.sh camel-4.14.2-branch "-Dtest=CICSGatwayTest"
```

That's it! You now have a working CICS TG environment and can run integration tests.

## Container Management

### Available Scripts

| File | Purpose |
|------|---------|
| **run-cics-container.sh** | Manage CICS TG 10.1 container |
| **run-tests.sh** | Run Camel CICS integration tests |

### Container Commands

```bash
./run-cics-container.sh pull                   # Pull image from Red Hat registry
./run-cics-container.sh run                    # Start container
./run-cics-container.sh stop                   # Stop container
./run-cics-container.sh restart                # Restart container
./run-cics-container.sh logs                   # View logs (follow mode)
./run-cics-container.sh shell                  # Open bash shell in container
./run-cics-container.sh status                 # Check container and CTG status
./run-cics-container.sh clean                  # Remove container (keep image)
./run-cics-container.sh clean-all              # Remove container and image
```

### Direct Docker Commands

If you prefer to use Docker commands directly:

```bash
# Pull image
docker pull images.paas.redhat.com/fuseqe/ibm-cicstg-container-linux-x86-trial:10.1

# Run container
docker run -d --name cics-ctg \
  -e LICENSE=accept \
  -p 2006:2006 -p 2035:2035 \
  images.paas.redhat.com/fuseqe/ibm-cicstg-container-linux-x86-trial:10.1

# Check status
docker ps | grep cics-ctg

# View logs
docker logs -f cics-ctg

# Stop and remove
docker stop cics-ctg
docker rm cics-ctg
```

### Container Details

**Image:** `images.paas.redhat.com/fuseqe/ibm-cicstg-container-linux-x86-trial:10.1`

**Ports:**
- **2006** - CTG gateway daemon (main port for CICS connections)
- **2035** - CTG SSL port
- **2810** - Admin port (used by tests)

**License:** Requires `LICENSE=accept` environment variable (automatically set by run-cics-container.sh)

## Running Integration Tests

### Test Runner Script

The `run-tests.sh` script automates the entire test process:

```bash
# Run tests with default branch (camel-4.14.2-branch)
./run-tests.sh

# Run tests with specific branch
./run-tests.sh camel-4.14.2-branch
./run-tests.sh camel-4.8-branch

# Run specific test class
./run-tests.sh camel-4.14.2-branch "-Dtest=CICSGatwayTest"

# Run specific test method
./run-tests.sh camel-4.14.2-branch "-Dtest=CICSGatwayTest#testSimpleECI"

# Run with Maven debug output
./run-tests.sh camel-4.14.2-branch "-X"

# Use custom Maven settings.xml file
./run-tests.sh --settings ~/.m2/my-settings.xml
./run-tests.sh -s /path/to/custom-settings.xml camel-4.14.2-branch

# Combine settings with specific test
./run-tests.sh --settings ~/.m2/settings.xml camel-4.14.2-branch "-Dtest=CICSGatwayTest#testSimpleECI"

# Use existing repository (skip clone)
SKIP_CLONE=true ./run-tests.sh
```

### Integration Tests vs Unit Tests

**IMPORTANT:** Not all tests connect to the CICS container. The test suite contains both:

**Integration Tests** (connect to CICS container):
```bash
# These tests actually connect to localhost:2006 and generate connection logs
./run-tests.sh --settings ~/.m2/settings-tnb.xml camel-4.14.2-branch \
  "-Dtest=*ConnectionFactoryTest,CustomBindingTest,CustomEncodingTest"
```

Tests that connect to CICS:
- `SingleConnectionFactoryTest` - Tests single connection factory
- `PooledConnectionFactoryTest` - Tests connection pooling
- `NoConnectionFactoryTest` - Tests without factory
- `CustomBindingTest` - Tests custom ECI bindings
- `CustomEncodingTest` - Tests encoding handling

**Unit Tests** (use mocks, don't connect):
```bash
# These tests use mocks and will NOT show connection logs
./run-tests.sh --settings ~/.m2/settings-tnb.xml camel-4.14.2-branch \
  "-Dtest=CICSGatwayTest,CICSCallTypeTest,GatewayPoolTest"
```

Tests that use mocks:
- `CICSGatwayTest` - Unit test for gateway logic (mocks)
- `CICSCallTypeTest` - Unit test for call types (mocks)
- `GatewayPoolTest` - Unit test for pool management (mocks)
- `CicsBindingTest` - Unit test for bindings (mocks)
- `CICSChannelEciBindingTest` - Unit test for channels (mocks)

**To verify container connectivity**, use the integration tests and monitor logs:

```bash
# Terminal 1: Monitor connections
docker logs -f cics-ctg-container 2>&1 | grep "CTG650"

# Terminal 2: Run integration tests
./run-tests.sh --settings ~/.m2/settings-tnb.xml camel-4.14.2-branch \
  "-Dtest=CustomBindingTest#shouldContainsCustomHeaders"
```

You'll see connection logs like:
```
CTG6506I Client connected: [ConnectionManager-0] - tcp@Socket[addr=/172.17.0.1,port=41444,localport=2006]
CTG6507I Client disconnected: [ConnectionManager-0] - tcp@Socket[addr=/172.17.0.1,port=41444,localport=2006]
```

**Note on Test Failures:**

Integration tests will fail with errors like:
- `ECI_ERR_UNKNOWN_SERVER` (return code -22)
- `NullPointerException: Cannot read the array length because "bytes" is null`

This is **expected** because the trial CTG container doesn't have a backend CICS server configured. The important verification is:
- ✅ Tests connect to the container (connection logs appear)
- ✅ CTG accepts and processes requests
- ✅ Error responses are returned (proving the connection works)

The connection infrastructure is working correctly - the failures are due to the missing CICS server backend, which is normal for a standalone CTG container.

### What the Test Runner Does

1. Checks prerequisites (Java 17, Maven, Docker, Git)
2. Verifies IBM CTG Client JAR is installed in local Maven repository
   - If missing and CICS container is running: automatically extracts and installs it
   - If missing and container not running: provides clear instructions
3. Creates work directory in `/tmp/camel-ibm-cics-test`
4. Clones fuse-components repository to `/tmp/camel-ibm-cics-test/fuse-components` (or uses existing)
5. Checks out specified branch
6. Validates CICS TG image availability
7. Detects image version mismatches
8. **Configures tests to use local container** (if running)
   - If `cics-ctg-container` is running: modifies tests to connect to `localhost:2006`
   - If not running: tests will use Testcontainers to start a new instance
   - This avoids duplicate containers and makes tests faster
9. Runs Maven tests
10. Displays test summary and reports

### Using Local vs Testcontainers

The test runner intelligently detects if you have a local CICS container running and automatically configures tests to use it:

**Scenario 1: Local Container Running** (Recommended)
```bash
# Start your local container first
./run-cics-container.sh run

# Run tests - they will connect to localhost:2006
./run-tests.sh
```

Benefits:
- ✅ Faster test execution (no container startup time)
- ✅ Only one CICS container instance
- ✅ Same container for manual testing and automated tests
- ✅ Easier debugging (container keeps running after tests)

**Scenario 2: No Local Container**
```bash
# Run tests without starting container first
./run-tests.sh
```

The tests will:
- Use Testcontainers to start a temporary CICS container
- Run tests against it
- Stop and remove the container when done

**Note:** The script creates a backup of the original test file at `AbstractCICSContainerizedTest.java.backup` before modifying it.

### Working Directory and Cleanup

The test runner uses `/tmp/camel-ibm-cics-test` as the working directory to keep test artifacts separate from your current directory.

**Cleanup after tests:**
```bash
# Remove all test artifacts and cloned repository
rm -rf /tmp/camel-ibm-cics-test

# Or just the repository
rm -rf /tmp/camel-ibm-cics-test/fuse-components
```

**Test reports location:**
```
/tmp/camel-ibm-cics-test/fuse-components/camel-cics/target/surefire-reports/
```

### Manual Test Execution

If you prefer to run tests manually:

```bash
# Clone the repository
git clone https://github.com/jboss-fuse/fuse-components.git
cd fuse-components

# Checkout the desired branch
git checkout camel-4.14.2-branch

# Navigate to camel-cics module
cd camel-cics

# Run all tests
mvn clean test

# Run specific test class
mvn test -Dtest=CICSGatwayTest

# Run specific test method
mvn test -Dtest=CICSGatwayTest#testSimpleECI

# Run with debug logging
mvn test -X
```

## Test Structure

### How Tests Work

The integration tests use **Testcontainers** to automatically manage the CICS TG container:

1. **Test starts** → Testcontainers pulls CICS TG image (if not present)
2. **Container launch** → Starts container with `LICENSE=accept`, exposes ports 2006/2810
3. **Configuration** → Copies custom `ctg.ini` from test resources
4. **Wait for ready** → Waits for log message: `CTG6512I CICS Transaction Gateway initialization complete`
5. **Run tests** → Executes test methods
6. **Cleanup** → Automatically stops and removes container

**Note:** You don't need to manually start the container for tests - Testcontainers handles it automatically!

### Test Types

#### Containerized Integration Tests

Tests extending `AbstractCICSContainerizedTest` (require CICS TG container):

- `CICSGatwayTest.java` - Gateway connectivity tests
- `CICSChannelEciBindingTest.java` - Channel and ECI binding tests
- `CicsBindingTest.java` - CICS binding tests
- `CustomBindingTest.java` - Custom binding tests
- `CustomEncodingTest.java` - Encoding tests
- `GatewayPoolTest.java` - Connection pool tests
- `PooledConnectionFactoryTest.java` - Pooled connection factory tests

#### Unit Tests

Tests that don't require CICS TG:

- `NoConnectionFactoryTest.java` - Configuration tests
- `CICSCallTypeTest.java` - Call type tests

### Test Configuration

**CTG Configuration (`ctg.ini`):**
- Located at: `camel-cics/src/test/resources/ctg.ini`
- TCP Protocol on port 2006
- Admin port 2810
- Health check plugin enabled

**Maven Dependencies:**
- CTG Client: Version 9.2
- Camel Version: 4.14.2
- Testcontainers: JUnit 5 integration
- Java: 17

### Test Reports

Test results are saved in:
```
/tmp/camel-ibm-cics-test/fuse-components/camel-cics/target/surefire-reports/
```

The `run-tests.sh` script automatically displays a summary of test results.

## Advanced Configuration

### Environment Variables

```bash
# For test runner
SKIP_CLONE=true              # Skip git clone, use existing repo
MAVEN_OPTS="-Xmx2g"         # Custom Maven JVM options

# For Maven tests
JAVA_HOME=/path/to/jdk17    # Use specific Java version
```

### Running Tests in CI/CD

```bash
# Minimal output
mvn clean test -q

# Generate JUnit XML reports
mvn clean test -Dsurefire.useFile=true

# With code coverage
mvn clean test jacoco:report
```

### Custom Maven Settings

If you need custom Maven settings, you can specify a custom `settings.xml` file:

**Using the test runner script:**
```bash
# Use custom settings with default branch
./run-tests.sh --settings ~/.m2/my-settings.xml

# Use custom settings with specific branch
./run-tests.sh -s /path/to/custom-settings.xml camel-4.14.2-branch

# Combine with other options
./run-tests.sh --settings ~/.m2/my-settings.xml camel-4.14.2-branch "-Dtest=CICSGatwayTest"
```

**For manual Maven execution:**
```bash
mvn test -s /path/to/custom-settings.xml
```

### Image Version Configuration

The tests currently reference the CICS TG image in `AbstractCICSContainerizedTest.java`:

```java
new GenericContainer<>("images.paas.redhat.com/fuseqe/ibm-cicstg-container-linux-x86-trial:10.1")
```

If the image version in the tests differs from yours (e.g., 9.3 vs 10.1), you'll be warned by `run-tests.sh` and can update the file accordingly.

## Troubleshooting

### Container Issues

**Container not starting?**
```bash
# Check logs
./run-cics-container.sh logs

# Verify ports are available
netstat -an | grep 2006

# Check Docker resources
docker info
```

**Can't pull image?**
```bash
# Verify registry access
docker pull images.paas.redhat.com/fuseqe/ibm-cicstg-container-linux-x86-trial:10.1

# Check Docker login status
docker login images.paas.redhat.com
```

**CTG not listening on port 2006?**
- Wait 30-60 seconds for CTG to fully start
- Check status: `./run-cics-container.sh status`
- View logs: `./run-cics-container.sh logs`

**License acceptance error?**
- The `LICENSE=accept` environment variable should be set automatically by run-cics-container.sh
- If running manually, ensure: `docker run -e LICENSE=accept ...`

### Test Issues

**Tests fail with "Could not find or load main class"**
```bash
cd fuse-components/camel-cics
mvn clean compile test
```

**Testcontainers can't pull the image**
```bash
# Verify Docker access
docker pull images.paas.redhat.com/fuseqe/ibm-cicstg-container-linux-x86-trial:10.1

# Check Docker daemon is running
docker ps
```

**Tests timeout waiting for CTG to start**
- Increase Docker resources (memory/CPU)
- Or update timeout in `AbstractCICSContainerizedTest.java`:
```java
.withStartupTimeout(Duration.ofSeconds(120L));  // Increase from 60 to 120
```

**Connection refused errors**
```bash
# Check container logs
docker logs <container-id>

# Verify CTG is listening
docker exec <container-id> netstat -an | grep 2006
```

**Maven can't download dependencies**
- Verify access to Red Hat repositories
- Check Maven settings.xml for credentials
- Try: `mvn dependency:resolve`

**Image version mismatch (9.3 vs 10.1)**

Update `AbstractCICSContainerizedTest.java`:
```java
new GenericContainer<>("images.paas.redhat.com/fuseqe/ibm-cicstg-container-linux-x86-trial:10.1")
```

**Java version issues**
```bash
# Verify Java version
java -version

# Should be Java 17 or later
# Set JAVA_HOME if needed
export JAVA_HOME=/path/to/jdk17
```

### Common Test Scenarios

**Run all integration tests:**
```bash
./run-tests.sh
```

**Run specific test class:**
```bash
./run-tests.sh camel-4.14.2-branch "-Dtest=CICSGatwayTest"
```

**Run with verbose output:**
```bash
./run-tests.sh camel-4.14.2-branch "-X"
```

**Skip tests during build:**
```bash
cd fuse-components/camel-cics
mvn clean install -DskipTests
```

## Documentation

### Related Resources

- [IBM CICS Transaction Gateway Documentation](https://www.ibm.com/docs/en/cics-tg-multi/10.1.0)
- [Apache Camel CICS Component](https://camel.apache.org/components/latest/cics-component.html)
- [Camel CICS Test Repository](https://github.com/jboss-fuse/fuse-components/tree/camel-4.14.2-branch/camel-cics)
- [Testcontainers Documentation](https://www.testcontainers.org/)

### Container Version

**CICS TG 10.1** - Latest version available from Red Hat internal registry
- Source: `images.paas.redhat.com/fuseqe/ibm-cicstg-container-linux-x86-trial:10.1`
- Setup: Simple pull and run
- Licensed from IBM, uploaded to Red Hat registry for FuseQE team

### Available Branches

Common branches in fuse-components repository:
- `camel-4.14.2-branch` (default)
- `camel-4.8-branch`
- `main`

### Support

For issues with:
- **CICS TG Container** - Contact IBM support or FuseQE team
- **Camel CICS Component** - Open issue in [fuse-components repository](https://github.com/jboss-fuse/fuse-components/issues)
- **Test Infrastructure** - Contact Red Hat Fuse QE team

---

## Example Workflow

Here's a complete example workflow from setup to running tests:

```bash
# 1. Start CICS TG container
./run-cics-container.sh pull
./run-cics-container.sh run

# 2. Verify it's running
./run-cics-container.sh status

# 3. Run integration tests
./run-tests.sh camel-4.14.2-branch

# 4. Run specific test for debugging
./run-tests.sh camel-4.14.2-branch "-Dtest=CICSGatwayTest -X"

# 5. When done, clean up
./run-cics-container.sh stop
```

For manual testing without Testcontainers, keep the container running and point your Camel CICS applications to `localhost:2006`.
