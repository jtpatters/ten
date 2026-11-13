SIM ?= iPad Pro 11-inch (M5)

.PHONY: project test sim headless determinism balance balance-sizes opponents narrate open

SEED ?= 1

project:            ## Generate TenThousandYears.xcodeproj from project.yml
	xcodegen generate

open: project       ## Generate and open in Xcode
	open TenThousandYears.xcodeproj

test:               ## Run engine unit tests (macOS, fast)
	cd Packages/Engine && swift test

headless:           ## Determinism + perf check: Large map, 100 turns of random moves, 300 extra units
	cd Packages/Engine && swift run -c release headless-sim --random --size large --seed 42 --turns 100 --extra-units 300

determinism:        ## The same AI game in two processes must end with the same state hash
	cd Packages/Engine && swift build -c release --product headless-sim
	@cd Packages/Engine && bin=$$(swift build -c release --show-bin-path) && \
	  run1=$$("$$bin/headless-sim" --ai --size duel --seed 7 --turns 100) || { echo "determinism: run 1 failed"; exit 1; }; \
	  run2=$$("$$bin/headless-sim" --ai --size duel --seed 7 --turns 100) || { echo "determinism: run 2 failed"; exit 1; }; \
	  hash1=$$(printf '%s\n' "$$run1" | grep 'final hash'); hash2=$$(printf '%s\n' "$$run2" | grep 'final hash'); \
	  echo "run 1: $$hash1"; echo "run 2: $$hash2"; \
	  if [ -z "$$hash1" ] || [ "$$hash1" != "$$hash2" ]; then echo "determinism: FAILED"; exit 1; fi; \
	  echo "determinism: OK"

balance:            ## AI balance (M1 §17 targets): 20 AI-vs-AI Duel games (seeds 1-20) of 150 turns
	cd Packages/Engine && swift run -c release headless-sim --ai --games 20 --size duel --seed 1 --turns 150

balance-sizes:      ## AI balance and timings on Small and Standard: 5 games each of 150 turns
	cd Packages/Engine && swift run -c release headless-sim --ai --games 5 --size small --seed 1 --turns 150
	cd Packages/Engine && swift run -c release headless-sim --ai --games 5 --size standard --seed 1 --turns 150

opponents:          ## The AI against a scripted turtle, then the scripted player, in seat 0 (Duel, 20 games)
	cd Packages/Engine && swift run -c release headless-sim --ai --games 20 --size duel --seed 1 --turns 150 --p0 turtle
	cd Packages/Engine && swift run -c release headless-sim --ai --games 20 --size duel --seed 1 --turns 150 --p0 scripted

narrate:            ## One narrated AI Duel game (make narrate SEED=3): a line per notable AI decision
	cd Packages/Engine && swift run -c release headless-sim --ai --size duel --seed $(SEED) --turns 150 --narrate

sim: project        ## Build the iOS app for the simulator
	xcodebuild -project TenThousandYears.xcodeproj -scheme TenThousandYears \
	  -destination 'platform=iOS Simulator,name=$(SIM),OS=latest' -derivedDataPath build build
