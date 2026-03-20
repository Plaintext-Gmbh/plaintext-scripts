#!/bin/bash
#
# Optimized Build Script
# Supports local development and CI usage
#
# Performance optimizations:
# - Parallel builds with -T 4
# - Maven build cache for incremental builds
# - Optional code coverage (via -Pcoverage)
#
# Usage:
#   ./build.sh                    # Fast build (no coverage)
#   ./build.sh --coverage         # Build with coverage
#   ./build.sh --clean            # Clean build
#   ./build.sh --skip-tests       # Skip tests
#   ./build.sh --help             # Show help

set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Default options
COVERAGE=false
CLEAN=false
SKIP_TESTS=false
THREADS=4
MAVEN_OPTS="${MAVEN_OPTS:--Xmx2g}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --coverage)
            COVERAGE=true
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        --threads)
            THREADS="$2"
            shift 2
            ;;
        --help|-h)
            echo -e "${BLUE}Usage: $0 [OPTIONS]${NC}"
            echo ""
            echo "Options:"
            echo "  --coverage       Enable code coverage (JaCoCo)"
            echo "  --clean          Run clean before build"
            echo "  --skip-tests     Skip running tests"
            echo "  --threads N      Number of parallel threads (default: 4)"
            echo "  --help, -h       Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                    # Fast build"
            echo "  $0 --coverage         # Build with coverage"
            echo "  $0 --clean --coverage # Clean build with coverage (CI mode)"
            echo "  $0 --threads 8        # Build with 8 threads"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Run '$0 --help' for usage information."
            exit 1
            ;;
    esac
done

# Use mvnw if available, otherwise mvn
MVN_CMD="mvn"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/mvnw" ]]; then
    MVN_CMD="$SCRIPT_DIR/mvnw"
fi

MVN_CMD="${MVN_CMD} -B -T ${THREADS}"

if [ "$CLEAN" = true ]; then
    MVN_CMD="${MVN_CMD} clean"
fi

MVN_CMD="${MVN_CMD} package"

if [ "$COVERAGE" = true ]; then
    MVN_CMD="${MVN_CMD} -Pcoverage"
    echo -e "${BLUE}Building with code coverage enabled${NC}"
fi

if [ "$SKIP_TESTS" = true ]; then
    MVN_CMD="${MVN_CMD} -DskipTests"
    echo -e "${YELLOW}Skipping tests${NC}"
fi

# Print build configuration
echo -e "${BLUE}=== Build Configuration ===${NC}"
echo -e "${BLUE}Threads:      ${GREEN}${THREADS}${NC}"
echo -e "${BLUE}Coverage:     ${GREEN}${COVERAGE}${NC}"
echo -e "${BLUE}Clean:        ${GREEN}${CLEAN}${NC}"
echo -e "${BLUE}Skip Tests:   ${GREEN}${SKIP_TESTS}${NC}"
echo -e "${BLUE}Maven Opts:   ${GREEN}${MAVEN_OPTS}${NC}"
echo ""
echo -e "${BLUE}Command: ${GREEN}${MVN_CMD}${NC}"
echo ""

# Run build
START_TIME=$(date +%s)

export MAVEN_OPTS
$MVN_CMD

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Print summary
echo ""
echo -e "${GREEN}=== Build Completed Successfully ===${NC}"
echo -e "${GREEN}Duration: ${DURATION} seconds${NC}"

# Show coverage report location if enabled
if [ "$COVERAGE" = true ]; then
    echo ""
    echo -e "${BLUE}Coverage reports available at:${NC}"
    find . -path "*/target/site/jacoco/index.html" -type f | head -5 | while read report; do
        echo -e "  ${GREEN}${report}${NC}"
    done
fi
