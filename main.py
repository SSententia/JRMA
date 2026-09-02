import os
import discord
from discord.ext import commands

# Check
print("Main loaded")

# Token
my_secret = os.environ.get('TOKEN')
if not my_secret:
    raise Exception("You forgor the token! :crying:")

# Intents
intents = discord.Intents.default()
intents.messages = True
intents.dm_messages = True
intents.message_content = True  # Enable message content intent

# Initialize the bot
bot = commands.Bot(command_prefix='!', intents=intents)

@bot.event
async def on_ready():
    print(f'We have logged in as {bot.user}')

@bot.event
async def on_message(message):

    # Check if the message is a DM to the bot and not from the bot itself
    if message.guild is None and not message.author.bot:

        # Split the message to extract the channel ID and the message content
        try:
            channel_id, msg_content = message.content.split(' ', 1)
            channel_id = int(channel_id)

            # Fetch the channel
            channel = bot.get_channel(channel_id)
            if channel:
                await channel.send(msg_content)
                await message.channel.send(f'Message sent to {channel.name}. hehe >:D')
            else:
                await message.channel.send("Bro, I can't find the channel")
        except (ValueError, discord.errors.Forbidden) as e:
            print(f"Error: {e}")
            await message.channel.send('Somethin is invalid. Check ur message')

# Run the bot
try:
    bot.run(my_secret)
except discord.HTTPException as e:
    if e.status == 429:
        print("Sh#t, they didn't let me in :crying: The rate limit is too high")
        print("Get some help from https://stackoverflow.com/questions/66724687/in-discord-py-how-to-solve-the-error-for-toomanyrequests")
    else:
        raise e
