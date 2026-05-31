exports.handler = async (event, context) => {
    console.log(`Function ${process.env.K_SERVICE} executed at ${new Date().toISOString()}`);
    return { status: 'success', message: 'Function executed successfully' };
};
