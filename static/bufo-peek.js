// bufo peeking animation logic
// this file handles the silly but delightful bufo that peeks from random edges

(function() {
    const peekingBufo = document.getElementById('peekingBufo');
    let hasSearched = false;

    // animation cycle duration (must match CSS animation duration)
    const PEEK_CYCLE_MS = 6000;

    // function to set random bufo position
    function setRandomBufoPosition() {
        const positions = ['top', 'right', 'bottom', 'left'];

        // remove all position classes
        peekingBufo.classList.remove(
            'peeking-bufo-top',
            'peeking-bufo-right',
            'peeking-bufo-bottom',
            'peeking-bufo-left'
        );

        // set new random position
        const position = positions[Math.floor(Math.random() * positions.length)];
        peekingBufo.classList.add(`peeking-bufo-${position}`);
    }

    // set initial position
    setRandomBufoPosition();

    // move to new position after each peek cycle
    setInterval(() => {
        if (!hasSearched) {
            setRandomBufoPosition();
        }
    }, PEEK_CYCLE_MS);

    // hide bufo after first search
    window.addEventListener('bufo-hide', () => {
        hasSearched = true;
        peekingBufo.classList.add('hidden');
    });
})();
