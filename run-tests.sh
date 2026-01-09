#!/bin/bash

##############################################################################
# Script to run Camel CICS integration tests
# Clones fuse-components repository and runs camel-cics tests
##############################################################################

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Configuration
DEFAULT_BRANCH="camel-4.14.2-branch"
REPO_URL="https://github.com/jboss-fuse/fuse-components.git"
WORK_DIR="/tmp/camel-ibm-cics-test"
REPO_DIR="$WORK_DIR/fuse-components"
MODULE_DIR="camel-cics"
CICS_IMAGE="images.paas.redhat.com/fuseqe/ibm-cicstg-container-linux-x86-trial:10.1"

# Global variables for arguments
BRANCH=""
MAVEN_ARGS=""
MAVEN_SETTINGS=""

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [BRANCH] [MAVEN_ARGS]

Arguments:
    BRANCH          Git branch to checkout (default: $DEFAULT_BRANCH)
    MAVEN_ARGS      Additional Maven arguments (optional)

Options:
    -s, --settings FILE     Path to custom Maven settings.xml file
    -h, --help              Show this help message

Examples:
    $0                              # Use default branch
    $0 camel-4.14.2-branch          # Specific branch
    $0 camel-4.14.2-branch "-X"     # With Maven debug output
    $0 camel-4.14.2-branch "-Dtest=CICSGatwayTest"  # Run specific test
    $0 camel-4.14.2-branch "-Dtest=CICSGatwayTest#testSimpleECI"  # Run specific test method
    $0 --settings ~/.m2/my-settings.xml camel-4.14.2-branch  # Custom settings
    $0 -s /path/to/settings.xml     # Custom settings with default branch
    $0 --settings ~/.m2/settings.xml camel-4.14.2-branch "-Dtest=CICSGatwayTest#testSimpleECI"  # All together

Environment Variables:
    SKIP_CLONE      Set to 'true' to skip git clone (use existing repo)
    MAVEN_OPTS      Additional Maven JVM options

Working Directory:
    The repository will be cloned to: $WORK_DIR/fuse-components
    This keeps test artifacts separate from the current directory.

Available Branches:
    - camel-4.14.2-branch (default)
    - camel-4.8-branch
    - main

EOF
}

check_prerequisites() {
    print_step "Checking prerequisites..."

    # Check Java
    if ! command -v java &> /dev/null; then
        print_error "Java is not installed or not in PATH"
        exit 1
    fi
    JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d'.' -f1)
    if [ "$JAVA_VERSION" -lt 17 ]; then
        print_error "Java 17 or later is required (found version $JAVA_VERSION)"
        exit 1
    fi
    print_info "Java version: $(java -version 2>&1 | head -n 1)"

    # Check Maven
    if ! command -v mvn &> /dev/null; then
        print_error "Maven is not installed or not in PATH"
        exit 1
    fi
    print_info "Maven version: $(mvn -version | head -n 1)"

    # Check Git
    if ! command -v git &> /dev/null; then
        print_error "Git is not installed or not in PATH"
        exit 1
    fi

    # Check Docker
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed or not in PATH"
        print_warn "Testcontainers requires Docker to run CICS TG container"
        exit 1
    fi
    print_info "Docker version: $(docker --version)"

    echo ""
}

check_ctg_client() {
    print_step "Checking IBM CTG Client JAR installation..."

    CTG_JAR_PATH="$HOME/.m2/repository/com/ibm/ctgclient/9.2/ctgclient-9.2.jar"

    if [ -f "$CTG_JAR_PATH" ]; then
        print_info "IBM CTG Client JAR found: $CTG_JAR_PATH"
        echo ""
        return
    fi

    print_warn "IBM CTG Client JAR not found in local Maven repository"
    print_warn "Expected location: $CTG_JAR_PATH"
    echo ""

    # Check if CICS container is running
    if docker ps | grep -q "cics-ctg-container"; then
        print_info "CICS TG container is running. Attempting automatic installation..."
        echo ""

        # Create temporary directory for extraction
        TEMP_JAR_FILE="/tmp/ctgclient-9.2-$$.jar"

        print_step "Step 1: Extracting CTG JAR from container..."
        # Try to find the CTG JAR in the container
        CTG_JAR_IN_CONTAINER=$(docker exec cics-ctg-container find /opt/ibm/ctg -name "ctgclient.jar" 2>/dev/null | head -1)

        if [ -z "$CTG_JAR_IN_CONTAINER" ]; then
            # Try alternative naming
            CTG_JAR_IN_CONTAINER=$(docker exec cics-ctg-container find /opt/ibm/ctg -name "*ctg*.jar" 2>/dev/null | grep -i client | head -1)
        fi

        if [ -z "$CTG_JAR_IN_CONTAINER" ]; then
            print_error "Could not find CTG client JAR in container"
            print_info "Searched in: /opt/ibm/ctg"
            echo ""
            print_info "Manual installation required. See README.md for details."
            exit 1
        fi

        print_info "Found CTG JAR in container: $CTG_JAR_IN_CONTAINER"

        # Copy JAR from container
        if docker cp "cics-ctg-container:$CTG_JAR_IN_CONTAINER" "$TEMP_JAR_FILE"; then
            print_info "Successfully extracted CTG JAR to: $TEMP_JAR_FILE"
        else
            print_error "Failed to copy CTG JAR from container"
            exit 1
        fi

        echo ""
        print_step "Step 2: Installing to local Maven repository..."

        # Install to Maven local repository
        if mvn install:install-file \
            -DgroupId=com.ibm \
            -DartifactId=ctgclient \
            -Dversion=9.2 \
            -Dpackaging=jar \
            -Dfile="$TEMP_JAR_FILE" -q; then
            print_info "Successfully installed CTG Client JAR to Maven repository"
            print_info "Location: $CTG_JAR_PATH"

            # Clean up temp file
            rm -f "$TEMP_JAR_FILE"
        else
            print_error "Failed to install CTG JAR to Maven repository"
            rm -f "$TEMP_JAR_FILE"
            exit 1
        fi

    else
        print_error "CICS TG container is not running"
        echo ""
        print_info "To install IBM CTG Client JAR, you need to:"
        echo ""
        print_info "1. Start the CICS TG container:"
        print_info "   ./run-cics-container.sh run"
        echo ""
        print_info "2. Re-run this script:"
        print_info "   $0"
        echo ""
        print_info "The script will automatically extract and install the JAR from the container."
        echo ""
        exit 1
    fi

    echo ""
}

clone_repository() {
    # Create work directory if it doesn't exist
    if [ ! -d "$WORK_DIR" ]; then
        print_info "Creating work directory: $WORK_DIR"
        mkdir -p "$WORK_DIR"
    fi

    if [ "${SKIP_CLONE}" = "true" ]; then
        print_info "Skipping repository clone (SKIP_CLONE=true)"
        if [ ! -d "$REPO_DIR" ]; then
            print_error "Repository directory '$REPO_DIR' not found"
            exit 1
        fi
        return
    fi

    if [ -d "$REPO_DIR" ]; then
        print_warn "Repository directory '$REPO_DIR' already exists"
        echo -n "Do you want to remove it and clone fresh? (y/N): "
        read -r response
        if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            print_info "Removing existing repository..."
            rm -rf "$REPO_DIR"
        else
            print_info "Using existing repository (will fetch and checkout branch)"
            cd "$REPO_DIR"
            print_step "Fetching latest changes..."
            git fetch origin
            print_step "Checking out branch: $BRANCH"
            git checkout "$BRANCH"
            git pull origin "$BRANCH"
            cd - > /dev/null
            return
        fi
    fi

    print_step "Cloning repository..."
    print_info "URL: $REPO_URL"
    print_info "Branch: $BRANCH"
    print_info "Destination: $REPO_DIR"

    git clone --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"

    if [ $? -eq 0 ]; then
        print_info "Repository cloned successfully"
    else
        print_error "Failed to clone repository"
        exit 1
    fi
}

check_cics_image() {
    print_step "Checking CICS TG container image..."

    if docker images | grep -q "ibm-cicstg-container"; then
        print_info "CICS TG image found locally"
        docker images | grep ibm-cicstg-container
    else
        print_warn "CICS TG image not found locally"
        print_info "Testcontainers will pull it automatically, or you can pull it now:"
        print_info "  docker pull $CICS_IMAGE"
        echo ""
    fi
}

update_test_image_version() {
    # Skip version check if using local container (we'll replace the file anyway)
    if docker ps | grep -q "cics-ctg-container"; then
        print_info "Using local CICS container - skipping image version check"
        echo ""
        return
    fi

    print_step "Checking test configuration for image version..."

    TEST_FILE="$REPO_DIR/$MODULE_DIR/src/test/java/com/redhat/camel/component/cics/AbstractCICSContainerizedTest.java"

    if [ -f "$TEST_FILE" ]; then
        CURRENT_IMAGE=$(grep -oP 'new GenericContainer<>\("\K[^"]+' "$TEST_FILE" || echo "not found")
        print_info "Current test image: $CURRENT_IMAGE"
        print_info "Expected image: $CICS_IMAGE"

        if [[ "$CURRENT_IMAGE" != "$CICS_IMAGE" ]]; then
            print_warn "Image version mismatch detected!"
            print_warn "The test uses: $CURRENT_IMAGE"
            print_warn "You have: $CICS_IMAGE"
            echo ""
            print_info "The test will use Testcontainers to pull and start: $CURRENT_IMAGE"
            print_info "To use version $CICS_IMAGE instead, edit:"
            print_info "  $TEST_FILE"
            echo ""
            print_info "Or start the local container to skip Testcontainers:"
            print_info "  ./run-cics-container.sh run"
            echo ""
            echo -n "Continue with version $CURRENT_IMAGE? (Y/n): "
            read -r response
            if [[ "$response" =~ ^([nN][oO]|[nN])$ ]]; then
                print_info "Aborted by user"
                exit 0
            fi
        fi
    fi
    echo ""
}

configure_local_container() {
    print_step "Configuring tests to use local CICS container..."

    # Check if local CICS container is running
    if ! docker ps | grep -q "cics-ctg-container"; then
        print_warn "Local CICS TG container is not running"
        print_info "Tests will use Testcontainers to start a new container instance"
        echo ""
        return
    fi

    print_info "Local CICS TG container detected - configuring tests to use it"

    TEST_FILE="$REPO_DIR/$MODULE_DIR/src/test/java/com/redhat/camel/component/cics/AbstractCICSContainerizedTest.java"

    if [ ! -f "$TEST_FILE" ]; then
        print_warn "Test file not found: $TEST_FILE"
        return
    fi

    # Create a backup
    cp "$TEST_FILE" "$TEST_FILE.backup"

    # Replace the test file to use local container instead of Testcontainers
    cat > "$TEST_FILE" << 'EOF'
package com.redhat.camel.component.cics;

import org.apache.camel.test.junit5.CamelTestSupport;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Modified to use local CICS TG container instead of Testcontainers
 * Connects to localhost:2006 (local running container)
 */
public class AbstractCICSContainerizedTest extends CamelTestSupport {

    public static final Logger LOG = LoggerFactory.getLogger(AbstractCICSContainerizedTest.class);

    /**
     * Mock container object that returns localhost and fixed ports
     * This allows tests to connect to the local running CICS container
     */
    protected static final MockCTGContainer ctgContainer = new MockCTGContainer();

    @Override
    protected void doPreSetup() throws Exception {
        // Skip - using local container, not starting new one
        LOG.info("Using local CICS TG container at localhost:2006");
    }

    /**
     * Mock container class that returns localhost connection details
     */
    static class MockCTGContainer {
        public boolean isRunning() {
            return true;
        }

        public String getHost() {
            return "localhost";
        }

        public int getMappedPort(int port) {
            // Return the same port - local container uses host network
            return port;
        }

        public void start() {
            // No-op - container already running
        }
    }
}
EOF

    print_info "Test configured to use local container at localhost:2006"
    print_info "Original test file backed up to: $TEST_FILE.backup"
    echo ""
}

run_tests() {
    print_step "Running Camel CICS integration tests..."
    echo ""

    # Validate settings file if provided
    if [ -n "$MAVEN_SETTINGS" ]; then
        if [ ! -f "$MAVEN_SETTINGS" ]; then
            print_error "Maven settings file not found: $MAVEN_SETTINGS"
            exit 1
        fi
        print_info "Using Maven settings: $MAVEN_SETTINGS"
    fi

    cd "$REPO_DIR/$MODULE_DIR"

    print_info "Working directory: $(pwd)"

    # Build Maven command
    MVN_CMD="mvn clean test"

    # Add settings file if provided
    if [ -n "$MAVEN_SETTINGS" ]; then
        MVN_CMD="$MVN_CMD -s $MAVEN_SETTINGS"
    fi

    # Add user-provided Maven arguments
    if [ -n "$MAVEN_ARGS" ]; then
        MVN_CMD="$MVN_CMD $MAVEN_ARGS"
    fi

    print_info "Maven command: $MVN_CMD"
    print_info "MAVEN_OPTS: ${MAVEN_OPTS:-<not set>}"
    echo ""

    print_step "Starting test execution..."
    echo "========================================================================"

    # Run Maven tests
    eval $MVN_CMD

    TEST_RESULT=$?

    echo "========================================================================"
    echo ""

    if [ $TEST_RESULT -eq 0 ]; then
        print_info "Tests completed successfully!"
    else
        print_error "Tests failed with exit code: $TEST_RESULT"
        exit $TEST_RESULT
    fi

    cd - > /dev/null
}

show_test_summary() {
    print_step "Test Summary"
    echo ""

    SUREFIRE_REPORTS="$REPO_DIR/$MODULE_DIR/target/surefire-reports"

    if [ -d "$SUREFIRE_REPORTS" ]; then
        print_info "Test reports location: $SUREFIRE_REPORTS"

        # Count test results
        TOTAL_TESTS=$(find "$SUREFIRE_REPORTS" -name "TEST-*.xml" -exec grep -h "tests=" {} \; 2>/dev/null | \
                      grep -oP 'tests="\K[0-9]+' | awk '{s+=$1} END {print s}')
        FAILED_TESTS=$(find "$SUREFIRE_REPORTS" -name "TEST-*.xml" -exec grep -h "failures=" {} \; 2>/dev/null | \
                       grep -oP 'failures="\K[0-9]+' | awk '{s+=$1} END {print s}')
        ERROR_TESTS=$(find "$SUREFIRE_REPORTS" -name "TEST-*.xml" -exec grep -h "errors=" {} \; 2>/dev/null | \
                      grep -oP 'errors="\K[0-9]+' | awk '{s+=$1} END {print s}')
        SKIPPED_TESTS=$(find "$SUREFIRE_REPORTS" -name "TEST-*.xml" -exec grep -h "skipped=" {} \; 2>/dev/null | \
                        grep -oP 'skipped="\K[0-9]+' | awk '{s+=$1} END {print s}')

        echo "  Total Tests:   ${TOTAL_TESTS:-0}"
        echo "  Passed:        $((${TOTAL_TESTS:-0} - ${FAILED_TESTS:-0} - ${ERROR_TESTS:-0} - ${SKIPPED_TESTS:-0}))"
        echo "  Failed:        ${FAILED_TESTS:-0}"
        echo "  Errors:        ${ERROR_TESTS:-0}"
        echo "  Skipped:       ${SKIPPED_TESTS:-0}"
        echo ""

        # List test classes
        print_info "Test classes executed:"
        find "$SUREFIRE_REPORTS" -name "TEST-*.xml" -exec basename {} \; 2>/dev/null | \
            sed 's/TEST-//;s/.xml$//' | sed 's/^/  - /'
    else
        print_warn "Surefire reports directory not found"
    fi
}

cleanup() {
    print_step "Cleanup"
    echo ""
    print_info "To remove the cloned repository:"
    print_info "  rm -rf $WORK_DIR"
    echo ""
    print_info "To remove Docker test containers:"
    print_info "  docker ps -a | grep testcontainers | awk '{print \$1}' | xargs docker rm -f"
}

# Main execution
main() {
    # Parse command line arguments
    local POSITIONAL_MODE=false

    while [[ $# -gt 0 ]]; do
        # Once we've seen the branch, everything else is Maven args (even if starts with -)
        if [[ "$POSITIONAL_MODE" == "true" ]]; then
            MAVEN_ARGS="$1"
            shift
        else
            case $1 in
                -s|--settings)
                    MAVEN_SETTINGS="$2"
                    shift 2
                    ;;
                -h|--help)
                    show_usage
                    exit 0
                    ;;
                --)
                    # Explicit end of options marker
                    POSITIONAL_MODE=true
                    shift
                    ;;
                -*)
                    # Check if we already have branch - if so, this is Maven args
                    if [ -n "$BRANCH" ]; then
                        MAVEN_ARGS="$1"
                        shift
                    else
                        print_error "Unknown option: $1"
                        echo ""
                        show_usage
                        exit 1
                    fi
                    ;;
                *)
                    # First positional argument is branch
                    if [ -z "$BRANCH" ]; then
                        BRANCH="$1"
                        POSITIONAL_MODE=true
                    else
                        # Second positional argument is Maven args
                        MAVEN_ARGS="$1"
                    fi
                    shift
                    ;;
            esac
        fi
    done

    # Set defaults for positional arguments
    BRANCH="${BRANCH:-$DEFAULT_BRANCH}"

    echo ""
    print_info "Camel CICS Integration Test Runner"
    print_info "=================================="
    echo ""
    print_info "Branch: $BRANCH"
    print_info "Image: $CICS_IMAGE"
    if [ -n "$MAVEN_SETTINGS" ]; then
        print_info "Maven Settings: $MAVEN_SETTINGS"
    fi
    echo ""

    check_prerequisites
    check_ctg_client
    clone_repository
    check_cics_image
    update_test_image_version
    configure_local_container
    run_tests
    show_test_summary
    cleanup

    echo ""
    print_info "Test execution complete!"
}

# Run main function
main "$@"
